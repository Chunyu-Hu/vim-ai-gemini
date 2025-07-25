" autoload/gemini.vim
" Contains most of the Vimscript logic, interaction with Python,
" and UI-related functions for the Gemini AI plugin.

" ============================================================================
" Global State Variables for Chat Sessions
" ============================================================================

" Global variable to store the current active chat session ID.
" Managed by gemini#StartChat and gemini#SwitchChat.
if !exists('g:gemini_current_chat_id')
    let g:gemini_current_chat_id = ''
endif

" Dictionary mapping session IDs (full string) to their Vim buffer numbers.
" Used to manage and locate chat buffers.
if !exists('g:gemini_chat_buffers')
    let g:gemini_chat_buffers = {}
endif

" Global variable to store the persistent buffer number for GeminiAsk responses.
if !exists('g:gemini_ask_display_bufnr')
    let g:gemini_ask_display_bufnr = -1
endif

" ============================================================================
" Python Interface Helpers
" ============================================================================

" Helper function to check for Python 3 support and return an error if missing.
function! s:check_python_support() abort
    if !has('python3')
        echoerr "Gemini.vim requires Vim compiled with Python 3 support."
        return 0
    endif
    return 1
endfunction

" Helper function to call a Python function and handle common errors.
" Args:
"   a:python_call_string: The string representing the Python function call (e.g., "gemini_api_handler.generate_content_from_file(...)")
" Returns:
"   A dictionary {success: bool, text: string, error: string}
function! s:call_python_and_parse_response(python_call_string) abort
    if !s:check_python_support()
        return {'success': v:false, 'error': "Python 3 support missing."}
    endif
    
    try
        let l:json_result = py3eval(a:python_call_string)
        let l:result = json_decode(l:json_result)
        return l:result
    catch /Vim\%(Python\|Py3\):/ " Catch Python errors specifically.
        let l:error_msg = v:exception
        echoerr "Python Error: " . l:error_msg
        return {'success': v:false, 'error': "Python execution failed: " . l:error_msg}
    catch /E117:/ " Catch Vimscript errors related to json_decode, etc.
        let l:error_msg = v:exception
        echoerr "Vimscript Error processing Python response: " . l:error_msg
        return {'success': v:false, 'error': "Vimscript error: " . l:error_msg}
    endtry
endfunction

" ============================================================================
" Content Generation Functions (Single-Turn & Visual)
" ============================================================================

" Core function to generate content from Gemini given a prompt.
" This calls the Python handler.
function! gemini#GenerateContent(prompt, model_name) abort
    " Pass prompt via temporary file to bypass Vimscript string literal issues.
    let l:temp_prompt_file = expand('~') . '/.vim_gemini_prompt_temp.txt'
    " Ensure the directory for the temp file exists.
    call mkdir(fnamemodify(l:temp_prompt_file, ':h'), 'p')
    " Write the raw prompt to a temporary file.
    call writefile(split(a:prompt, "\n"), l:temp_prompt_file)

    " JSON-encode other arguments (api_key_source, model_name).
    let l:api_key_source_json = json_encode(g:gemini_api_key_source)
    let l:model_name_json = json_encode(a:model_name)
    
    " Construct the Python call string to tell Python to read the prompt from the file.
    " JSON-encode the filepath itself.
    let l:temp_prompt_file_json = json_encode(l:temp_prompt_file)

    " The Python function called will be 'generate_content_from_file'.
    let l:call_string = "gemini_api_handler.generate_content_from_file(" .
                       \ l:temp_prompt_file_json . ", " .
                       \ l:api_key_source_json . ", " .
                       \ l:model_name_json . ")"
    
    let l:result = s:call_python_and_parse_response(l:call_string)

    " Delete temp file after use (crucial for cleanup).
    call delete(l:temp_prompt_file)

    if l:result.success
        return l:result.text
    else
        echoerr "Gemini API Error: " . l:result.error
        return ''
    endif
endfunction

" Manages a single, persistent buffer for GeminiAsk results.
function! s:update_ask_buffer(prompt_text, response_text, filetype_arg) abort
    if empty(a:prompt_text) && empty(a:response_text)
        echo "No content to display."
        return
    endif

    let l:original_win = winnr()
    let l:original_buf = bufnr('%')
    let l:original_pos = getpos('.')

    let l:target_bufnr = g:gemini_ask_display_bufnr

    " Check if the buffer exists and is valid.
    if l:target_bufnr == -1 || !bufexists(l:target_bufnr) || bufname(l:target_bufnr) !=# '[GeminiAsk Result]' || !buflisted(l:target_bufnr)
        let l:bufname = '[GeminiAsk Result]'
        " Always create in a vertical split.
        exe 'silent! keepjumps vnew'
        exe 'silent! file ' . l:bufname
        let l:target_bufnr = bufnr('%')

        " Set buffer options for a scratch buffer.
        setlocal buftype=nofile
        "setlocal bufhidden=hide
        exe 'setlocal filetype=' . a:filetype_arg
        
        " Store the new bufnr globally.
        let g:gemini_ask_display_bufnr = l:target_bufnr
    else
        " Buffer already exists, just switch to it.
        exe 'buffer ' . l:target_bufnr
    endif

    " Remove NULL bytes from response.
    let l:cleaned_response_text = substitute(a:response_text, '\x00', '', 'g')
    
    " Go to the very top of the buffer to insert new content.
    normal! gg
    
    " Prepare lines for Gemini's response.
    let l:gemini_lines = [
        \ '### Gemini:',
        \ ]
    call extend(l:gemini_lines, split(l:cleaned_response_text, "\n"))
    
    " Blank line after Gemini's response.
    call add(l:gemini_lines, '')


    " Prepare lines for User's prompt.
    let l:user_lines = [
        \ '### User:',
        \ ]
    call extend(l:user_lines, split(a:prompt_text, "\n"))
    
    " Blank line after user's prompt.
    call add(l:user_lines, '')
    
    " Add a separator before previous conversations, but only if there's existing content.
    " Using getbufinfo() and its 'linecount' field for robustness.
    if exists('*getbufinfo')
        let l:buf_info = getbufinfo(l:target_bufnr)
        " Check if getbufinfo found the buffer and it has lines.
        if !empty(l:buf_info) && get(l:buf_info[0], 'linecount', 0) > 0
            " Add separator at top.
            call append(0, ["", "---", ""])
        endif
    else
        " Fallback if getbufinfo() is not available (should be in Vim 7.4+).
        " Use linecount() function as a highly compatible alternative.
        if exists('*linecount')
            if linecount(l:target_bufnr) > 0
                call append(0, ["", "---", ""])
            endif
        else
            " Absolute fallback if neither exist: check visual lines.
            if !empty(getline(1, '$'))
                call append(0, ["", "---", ""])
            endif
        endif
    endif

    " Insert Gemini's response at the top (after separator if any).
    call append(0, l:gemini_lines)
    
    " Insert User's prompt just before Gemini's (so it appears above Gemini).
    call append(0, l:user_lines)

    " Go to the very top of the buffer (where new content was added).
    normal! gg

    call s:apply_gemini_highlights()

    " Ensure buffer is not marked as modified (for cleaner display).
    setlocal nomodified

    " Return to original buffer and position.
    exe l:original_win . 'wincmd w'
    exe 'buffer ' . l:original_buf
    call setpos('.', l:original_pos)
endfunction


" Command handler for :GeminiAsk
function! gemini#Ask(...) abort
    let l:prompt = ''
    if a:0 > 0
        let l:prompt = join(a:000, ' ')
    else
        let l:prompt = input("Ask Gemini: ")
    endif

    if empty(l:prompt)
        echo "Canceled or empty prompt."
        return
    endif

    echo "Asking Gemini..."
    let l:response = gemini#GenerateContent(l:prompt, g:gemini_default_model)

    if !empty(l:response) " Update the Ask buffer with user's prompt and Gemini's response.
        call s:update_ask_buffer(l:prompt, l:response, 'markdown')
        echo "Gemini response received."
    else
        echoerr "Gemini did not return a response."
    endif
endfunction

" Command handler for :GeminiAskVisual
function! gemini#AskVisual(...) abort range
    let l:original_win = winnr()
    let l:original_buf = bufnr('%')
    let l:original_pos = getpos('.')

    let l:start_line = line("'<")
    let l:end_line = line("'>")
    let l:selected_code = join(getline(l:start_line, l:end_line), "\n")

    " Fallback to clipboard registers if unnamed is empty (e.g., another yank happened or no selection).
    if empty(l:selected_code) && has('clipboard')
        let l:temp_clipboard_content_star = getreg('*')
        if !empty(l:temp_clipboard_content_star)
            let l:selected_code = l:temp_clipboard_content_star
        else
            let l:temp_clipboard_content_plus = getreg('+')
            if !empty(l:temp_clipboard_content_plus)
                let l:selected_code = l:temp_clipboard_content_plus
            endif
        endif
    endif

    if a:0 > 0
        let l:user_prompt_text = join(a:000, ' ')
    else
        let l:user_prompt_text = input("Ask Gemini: ")
    endif

    " Exit if user cancels or provides no prompt and no code selected.
    " Now, if l:user_prompt_text is empty, it means they didn't type anything after the command.
    if empty(l:user_prompt_text) && empty(l:selected_code)
        echo "Canceled or empty selection/prompt."
        return
    endif

    " Simplify the combined prompt: just concatenate, no markdown fences.
    let l:combined_prompt_for_gemini = ''
    if !empty(l:user_prompt_text)
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . l:user_prompt_text
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . "\n\n"
    endif
    if !empty(l:selected_code)
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . "Code:\n"
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . l:selected_code . "\n"
    endif

    echo "Sending combined prompt and code to Gemini..."
    
    " Call Python to generate content using the combined prompt.
    let l:response = gemini#GenerateContent(l:combined_prompt_for_gemini, g:gemini_default_model)

    if !empty(l:response)
        " Update the Ask buffer with the *full combined prompt* (including code) and Gemini's response.
        call s:update_ask_buffer(l:combined_prompt_for_gemini, l:response, 'markdown')
        echo "Gemini response received."
    else
        echoerr "Gemini did not return a response."
    endif

    " Return to original buffer and position.
    exe l:original_win . 'wincmd w'
    exe 'buffer ' . l:original_buf
    call setpos('.', l:original_pos)
endfunction


" Command handler for :GeminiGenerateVisual
function! gemini#SendVisualSelection() abort range
    let l:lastline = line("'>")
    let l:selected_text = join(getline(a:firstline, l:lastline), "\n")
    echo "Sending selected text to Gemini..."
    let l:response = gemini#GenerateContent(l:selected_text, g:gemini_default_model)

    if !empty(l:response)
        " Keeping s:display_in_new_buffer for these as they are transient.
        call s:update_ask_buffer("", l:response, 'markdown')
        echo "Gemini response received in new buffer."
    else
        echoerr "Gemini did not return a response."
    endif
endfunction

" Command handler for :GeminiGenerateBuffer
function! gemini#SendBuffer() abort
    let l:buffer_content = join(getline(1, '$'), "\n")
    echo "Sending entire buffer to Gemini..."
    let l:response = gemini#GenerateContent(l:buffer_content, g:gemini_default_model)

    if !empty(l:response)
        " Keeping s:display_in_new_buffer for these as they are transient.
        "call s:display_in_new_buffer(l:response, 'markdown')
        call s:update_ask_buffer("", l:response, 'markdown')
        echo "Gemini response received in new buffer."
    else
        echoerr "Gemini did not return a response."
    endif
endfunction

" Opens a new scratch buffer and populates it with text. (This function is kept for GenerateVisual/GenerateBuffer)
function! s:display_in_new_buffer(content, filetype_arg) abort
    if empty(a:content)
        echo "No content to display."
        return
    endif

    let l:original_win = winnr()
    let l:original_buf = bufnr('%')
    let l:original_pos = getpos('.')

    " Use :vnew to create a new vertical split for the response.
    exe 'silent! keepjumps vnew'
    
    " Set buffer options for the response buffer.
    setlocal buftype=nofile
    setlocal bufhidden=delete
    exe 'setlocal filetype=' . a:filetype_arg
    call append(0, split(a:content, "\n"))
    normal! gg

    call s:apply_gemini_highlights()

    " Return to original buffer and position.
    exe l:original_win . 'wincmd w'
    exe 'buffer ' . l:original_buf
    call setpos('.', l:original_pos)
endfunction


" Command handler for :GeminiReplaceVisual (in-place replacement)
function! gemini#SendVisualSelectionReplace() abort range
    " Save current view/cursor position (optional, good for undo/inspect).
    normal! gv"ay

    " Get the selected text.
    let l:start_line = a:firstline
    let l:end_line = a:lastline
    let l:selected_text = join(getline(l:start_line, l:end_line), "\n")

    echo "Sending selected text to Gemini for replacement..."

    " Call the Python function.
    let l:response = gemini#GenerateContent(l:selected_text, g:gemini_default_model)

    if !empty(l:response)
        " Delete the current visual selection.
        " Move cursor to start of selection, then delete.
        exe l:start_line . "normal! gv"
        normal! d

        " Get the current cursor position after deletion (start of deleted area).
        let l:cursor_line = line('.')
        let l:cursor_col = col('.')

        " Insert the response at the cursor position.
        let l:response_lines = split(l:response, "\n")
        call append(l:cursor_line - 1, l:response_lines)

        " Optionally, re-select the newly inserted text for visual feedback.
        let l:new_end_line = l:cursor_line - 1 + len(l:response_lines)
        exe l:cursor_line . "," . l:new_end_line . "normal! gv"

        echo "Gemini replacement complete."
    else
        echoerr "Gemini did not return a response."
    endif
endfunction


" ============================================================================
" Chat Session Functions
" ============================================================================

" Helper to define and apply custom highlighting.
" This function MUST be called after switching to the target buffer.
function! s:apply_gemini_highlights() abort
    " Define custom highlight groups if they don't exist.
    " Using default to let user's colorscheme override if desired.
    " User Prompts
    if !hlexists('GeminiUserPrompt')
        highlight default GeminiUserPrompt term=bold ctermfg=cyan gui=bold guifg=#00FFFF
    endif
    " AI Responses
    if !hlexists('GeminiAIResponse')
        highlight default GeminiAIResponse term=bold ctermfg=green gui=bold guifg=#00FF00
    endif
    " Section Headers (like ### User: / ### Gemini:)
    if !hlexists('GeminiHeader')
        highlight default GeminiHeader term=bold ctermfg=yellow gui=bold guifg=#FFFF00
    endif

    " Try to clear previous matches in the current buffer to avoid accumulation.
    " Using clearmatches() which clears all matches for the current buffer.
    if exists('*clearmatches')
        call clearmatches()
    endif

    " Apply matches for the specific headers in the current buffer.
    call matchadd('GeminiHeader', '^### User:', -1)
    call matchadd('GeminiUserPrompt', '^### User:.*', -1)
    
    call matchadd('GeminiHeader', '^### Gemini:', -1)
    call matchadd('GeminiAIResponse', '^### Gemini:.*', -1)
endfunction


function! s:get_chat_buffer(session_id, create_if_not_exists) abort
    " Check if buffer for this session ID already exists and is listed.
    if has_key(g:gemini_chat_buffers, a:session_id) && buflisted(get(g:gemini_chat_buffers, a:session_id, -1))
        return g:gemini_chat_buffers[a:session_id]
    endif

    " If not found, create if requested.
    if a:create_if_not_exists
        let l:bufname = '[Gemini Chat] ' . a:session_id[:7] " Use a prefix for buffer name.
        try
            " Use :vnew to create an empty buffer in a new vertical split, then :file to name it.
            exe 'silent! keepjumps vnew'
            exe 'silent! file ' . l:bufname

            let l:bufnr = bufnr(l:bufname)
            
            if l:bufnr == -1
                let l:bufnr = bufnr('%')
                if bufname(l:bufnr) !=# l:bufname
                    echoerr "Gemini.vim: Internal error - could not create unique chat buffer."
                    return -1
                endif
            endif

            " If a buffer was successfully created and identified.
            if l:bufnr != -1
                " Set buffer options for a scratch buffer. Keeping only essential ones that should always work.
                call setbufvar(l:bufnr, '&buftype', 'nofile')      " Marks as not a real file.
                call setbufvar(l:bufnr, '&bufhidden', 'delete')   " Deletes buffer when no windows show it.
                call setbufvar(l:bufnr, '&filetype', 'markdown')  " Sets syntax highlighting.
                
                " Store session ID in buffer-local variable for context.
                call setbufvar(l:bufnr, 'gemini_session_id', a:session_id)
                " Store bufnr in global map.
                let g:gemini_chat_buffers[a:session_id] = l:bufnr
                return l:bufnr
            endif
        catch
            echo "DEBUG: Error during buffer creation in s:get_chat_buffer: " . v:exception
            let l:bufnr = -1
        endtry
    endif
    return -1
endfunction


" Command handler for :GeminiChatStart
function! gemini#StartChat() abort
    let l:result = s:call_python_and_parse_response(
                \ printf("gemini_api_handler.start_gemini_chat_session('%s')", g:gemini_api_key_source))

    if l:result.success
        let g:gemini_current_chat_id = l:result.session_id
        echo "New Gemini chat session started: " . g:gemini_current_chat_id[:7]
        " Create and switch to the new chat buffer.
        let l:bufnr = s:get_chat_buffer(g:gemini_current_chat_id, 1)
        if l:bufnr != -1
            exe 'buffer ' . l:bufnr
            " Add a welcome message.
            call append(0, ["# Gemini Chat Session " . g:gemini_current_chat_id[:7], "---", ""])
            setlocal nomodified
        endif
    else
        echoerr "Failed to start chat: " . l:result.error
    endif
endfunction


" Command handler for :GeminiChatSend
function! gemini#SendMessage(message_text) abort
    if empty(g:gemini_current_chat_id)
        echoerr "No active Gemini chat session. Use :GeminiChatStart first."
        return
    endif
    
    let l:bufnr = s:get_chat_buffer(g:gemini_current_chat_id, 0)
    
    if l:bufnr == -1
        echoerr "Gemini Chat Error: The chat buffer for session '" . g:gemini_current_chat_id[:7] . "' is not active."
        echoerr "It might have been closed. Please start a new session with :GeminiChatStart, or try :GeminiChatSwitch " . g:gemini_current_chat_id[:7] . " if you believe it's still open."
        return
    endif

    let l:current_win = winnr()
    let l:current_buf = bufnr('%')
    let l:current_pos = getpos('.')

    echo "Sending message to Gemini in session " . g:gemini_current_chat_id[:7] . "..."

    " Switch to the chat buffer.
    exe 'buffer ' . l:bufnr
    " Append user message lines to the list of current lines.
	let l:user_lines = [
				\ '### User:',
				\ ]
    let l:cleaned_user_message = substitute(a:message_text, '\x00', '', 'g')
	call extend(l:user_lines, split(l:cleaned_user_message, "\n"))
    " Blank line after user's prompt.
    call add(l:user_lines, '')

    call append(line('$'), l:user_lines)

    call s:apply_gemini_highlights() " Apply highlights after appending.
    
    setlocal nomodified
    
    " Go to the chat buffer and move to the end.
    normal! G
    
    " Call Python to send the message and get response.
    " Use json_encode() for string arguments to ensure proper Python literal formatting.
    let l:session_id_json = json_encode(g:gemini_current_chat_id)
    let l:message_text_json = json_encode(a:message_text)
    let l:api_key_source_json = json_encode(g:gemini_api_key_source)

    let l:call_string = "gemini_api_handler.send_gemini_chat_message(" .
                       \ l:session_id_json . ", " .
                       \ l:message_text_json . ", " .
                       \ l:api_key_source_json . ")"

    let l:result = s:call_python_and_parse_response(l:call_string)

    if l:result.success
        " Attempt to remove NULL bytes (^@) from the response for cleaner display.
        let l:gemini_response_text = substitute(l:result.text, '\x00', '', 'g')
		" Prepare lines for Gemini's response.
		let l:gemini_lines = [
					\ '### Gemini:',
					\ ]
		call extend(l:gemini_lines, split(l:gemini_response_text, "\n"))

		" Blank line after Gemini's response.
		call add(l:gemini_lines, '')

        " Append Gemini's response lines to the list.
        call append(line('$'), l:gemini_lines)
        
        call s:apply_gemini_highlights()
        
        setlocal nomodified
        echo "Gemini replied in session " . g:gemini_current_chat_id[:7]
        normal! G " Ensure cursor is at the end of the chat buffer.
    else
        echoerr "Gemini chat error: " . l:result.error
    endif

    " Return to original buffer and position.
    exe l:current_win . 'wincmd w'
    exe 'buffer ' . l:current_buf
    call setpos('.', l:current_pos) " Restore cursor position.
endfunction

" Command handler for :GeminiChatSendVisual
function! gemini#SendVisualSelectionToChat() abort range
	let l:lastline = line("'>")
    let l:selected_text = join(getline(a:firstline, l:lastline), "\n")
    call gemini#SendMessage(l:selected_text)
endfunction

" Command handler for :GeminiChatSendBuffer
function! gemini#SendBufferToChat() abort
    let l:buffer_content = join(getline(1, '$'), "\n")
    call gemini#SendMessage(l:buffer_content)
endfunction

" Command handler for :GeminiChatList
function! gemini#ListChats() abort
    if empty(g:gemini_chat_buffers)
        echo "No active chat sessions."
        return
    endif
    echo "Active Gemini Chat Sessions:"
    for l:id in keys(g:gemini_chat_buffers)
        let l:bufnr = get(g:gemini_chat_buffers, l:id, -1)
        if buflisted(l:bufnr)
            echo "  - ID: " . l:id[:7] . " (Buffer: " . bufname(l:bufnr) . ")"
        else
            echo "  - ID: " . l:id[:7] . " (Buffer: NOT ACTIVE)"
        endif
    endfor
    echo "Current Session: " . (empty(g:gemini_current_chat_id) ? "None" : g:gemini_current_chat_id[:7])
endfunction

" Command handler for :GeminiChatSwitch
function! gemini#SwitchChat(session_id_prefix) abort
    " Find the full ID based on the prefix.
    let l:full_id = ''
    for l:id in keys(g:gemini_chat_buffers)
        if strpart(l:id, 0, len(a:session_id_prefix)) ==# a:session_id_prefix
            let l:full_id = l:id
            break
        endif
    endfor

    if empty(l:full_id)
        echoerr "Session ID prefix '" . a:session_id_prefix . "' not found."
        return
    endif

    let l:bufnr = s:get_chat_buffer(l:full_id, 0)
    if l:bufnr != -1
        exe 'buffer ' . l:bufnr
        let g:gemini_current_chat_id = l:full_id
        echo "Switched to chat session: " . l:full_id[:7]
        normal! G " Go to end of buffer.
    else
        echoerr "Chat buffer not active for session: " . l:full_id[:7] . ". Try restarting session or verify it's not hidden."
        " Optionally, you could add logic here to try to reload history if persistence is implemented.
    endif
endfunction

" Command handler for :GeminiChatEnd
function! gemini#EndChat(session_id_prefix) abort
    " Find the full ID based on the prefix.
    let l:full_id = ''
    for l:id in keys(g:gemini_chat_buffers)
        if strpart(l:id, 0, len(a:session_id_prefix)) ==# a:session_id_prefix
            let l:full_id = l:id
            break
        endif
    endfor

    if empty(l:full_id)
        echoerr "Session ID prefix '" . a:session_id_prefix . "' not found."
        return
    endif

    let l:result = s:call_python_and_parse_response(
                \ printf("gemini_api_handler.end_gemini_chat_session('%s')", l:full_id))

    if l:result.success
        if has_key(g:gemini_chat_buffers, l:full_id)
            let l:bufnr = g:gemini_chat_buffers[l:full_id]
            if buflisted(l:bufnr)
                exe 'bdelete! ' . l:bufnr
            endif
            call remove(g:gemini_chat_buffers, l:full_id)
        endif
        if g:gemini_current_chat_id ==# l:full_id
            let g:gemini_current_chat_id = ''
        endif
        echo l:result.message
    else
        echoerr "Failed to end chat: " . l:result.error
    endif
endfunction
