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
    let g:gemini_chat_buffers = {} " dict: full_session_id -> bufnr
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
"   a:python_call_string: The string representing the Python function call (e.g., "gemini_api_handler.generate_gemini_content(...)")
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
    catch /Vim\%(Python\|Py3\):/ " Catch Python errors specifically
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
" Content Generation Functions (Single-Turn)
" ============================================================================

" Core function to generate content from Gemini given a prompt.
" This calls the Python handler.
function! gemini#GenerateContent(prompt, model_name) abort
    let l:call_string = printf("gemini_api_handler.generate_gemini_content(%s, '%s', '%s')",
                               \ string(a:prompt), g:gemini_api_key_source, a:model_name)
    let l:result = s:call_python_and_parse_response(l:call_string)

    if l:result.success
        return l:result.text
    else
        echoerr "Gemini API Error: " . l:result.error
        return ''
    endif
endfunction

" Opens a new scratch buffer and populates it with text.
function! s:display_in_new_buffer(content, filetype_arg) abort
    if empty(a:content)
        echo "No content to display."
        return
    endif
    new
    setlocal buftype=nofile nobuflisted bufhidden=delete noswapfile
    exe 'setlocal filetype=' . a:filetype_arg
    call append(0, split(a:content, "\n"))
    normal! gg
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

    if !empty(l:response)
        call s:display_in_new_buffer(l:response, 'markdown')
        echo "Gemini response received."
    else
        echoerr "Gemini did not return a response."
    endif
endfunction

" Command handler for :GeminiGenerateVisual
function! gemini#SendVisualSelection() abort range
    let l:selected_text = join(getline(a:firstline, a:lastline), "\n")
    echo "Sending selected text to Gemini..."
    let l:response = gemini#GenerateContent(l:selected_text, g:gemini_default_model)

    if !empty(l:response)
        call s:display_in_new_buffer(l:response, 'markdown')
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
        call s:display_in_new_buffer(l:response, 'markdown')
        echo "Gemini response received in new buffer."
    else
        echoerr "Gemini did not return a response."
    endif
endfunction

" Command handler for :GeminiReplaceVisual (in-place replacement)
function! gemini#SendVisualSelectionReplace() abort range
    " Save current view/cursor position (optional, good for undo/inspect)
    normal! gv"ay

    " Get the selected text
    let l:start_line = a:firstline
    let l:end_line = a:lastline
    let l:selected_text = join(getline(l:start_line, l:end_line), "\n")

    echo "Sending selected text to Gemini for replacement..."

    " Call the Python function
    let l:response = gemini#GenerateContent(l:selected_text, g:gemini_default_model)

    if !empty(l:response)
        " Delete the current visual selection
        " Move cursor to start of selection, then delete
        exe l:start_line . "normal! gv"
        normal! d

        " Get the current cursor position after deletion (start of deleted area)
        let l:cursor_line = line('.')
        let l:cursor_col = col('.')

        " Insert the response at the cursor position
        let l:response_lines = split(l:response, "\n")
        call append(l:cursor_line - 1, l:response_lines)

        " Optionally, re-select the newly inserted text for visual feedback
        let l:new_end_line = l:cursor_line - 1 + len(l:response_lines)
        exe l:cursor_line . "," . l:new_end_line . "normal! gv"

        echo "Gemini replacement complete."
    else
        echoerr "Gemini did not return a response for replacement."
    endif
endfunction


" ============================================================================
" Chat Session Functions
" ============================================================================

" Helper to get/create a chat buffer for a given session ID.
function! s:get_chat_buffer(session_id, create_if_not_exists) abort
    " Check if buffer for this session ID already exists and is listed
    if has_key(g:gemini_chat_buffers, a:session_id) && buflisted(g:gemini_chat_buffers[a:session_id])
        return g:gemini_chat_buffers[a:session_id]
    endif

    " If not found, create if requested
    if a:create_if_not_exists
        let l:bufname = '[Gemini Chat] ' . a:session_id[:7] " Use a prefix for buffer name
        exe 'silent! keepjumps sbuffer ' . l:bufname
        let l:bufnr = bufnr(l:bufname)
        " Set buffer options for a scratch buffer
        call setbufvar(l:bufnr, '&buftype', 'nofile')
        call setbufvar(l:bufnr, '&nobuflisted', 1)
        call setbufvar(l:bufnr, '&bufhidden', 'delete')
        call setbufvar(l:bufnr, '&noswapfile', 1)
        call setbufvar(l:bufnr, '&filetype', 'markdown') " Markdown for chat formatting
        " Store session ID in buffer-local variable for context
        call setbufvar(l:bufnr, 'gemini_session_id', a:session_id)
        " Store bufnr in global map
        let g:gemini_chat_buffers[a:session_id] = l:bufnr
        return l:bufnr
    endif
    return -1 " Buffer not found and not created
endfunction

" Command handler for :GeminiChatStart
function! gemini#StartChat() abort
    let l:result = s:call_python_and_parse_response(
                \ printf("gemini_api_handler.start_gemini_chat_session('%s')", g:gemini_api_key_source))

    if l:result.success
        let g:gemini_current_chat_id = l:result.session_id
        echo "New Gemini chat session started: " . g:gemini_current_chat_id[:7]
        " Create and switch to the new chat buffer
        let l:bufnr = s:get_chat_buffer(g:gemini_current_chat_id, 1)
        if l:bufnr != -1
            exe 'buffer ' . l:bufnr
            " Optionally, add a welcome message
            call append(0, ["# Gemini Chat Session " . g:gemini_current_chat_id[:7], "---", ""])
            call setbufvar(l:bufnr, '&modified', 0)
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
        echoerr "No active chat buffer found for session: " . g:gemini_current_chat_id[:7]
        echoerr "Please restart session or verify it's not hidden."
        return
    endif

    let l:original_buf = bufnr('%') " Store current buffer to return later

    " Append user message to the active chat buffer
    call buf_set_lines(l:bufnr, -1, -1, [
        \ '### User:',
        \ a:message_text,
        \ ''
        \ ])
    call setbufvar(l:bufnr, '&modified', 0) " Mark as not modified after adding user text
    
    " Go to the chat buffer and move to the end
    exe 'buffer ' . l:bufnr
    normal! G

    echo "Sending message to Gemini in session " . g:gemini_current_chat_id[:7] . "..."

    " Call Python to send the message and get response
    let l:call_string = printf("gemini_api_handler.send_gemini_chat_message('%s', %s, '%s')",
                               \ g:gemini_current_chat_id, string(a:message_text), g:gemini_api_key_source)
    let l:result = s:call_python_and_parse_response(l:call_string)

    if l:result.success
        " Append Gemini's response to the chat buffer
        call buf_set_lines(l:bufnr, -1, -1, [
            \ '### Gemini:',
            \ l:result.text,
            \ ''
            \ ])
        call setbufvar(l:bufnr, '&modified', 0)
        echo "Gemini replied in session " . g:gemini_current_chat_id[:7]
        " Ensure cursor is at the end of the chat buffer
        normal! G
    else
        echoerr "Gemini chat error: " . l:result.error
    endif

    " Return to original buffer
    exe 'buffer ' . l:original_buf
endfunction

" Command handler for :GeminiChatSendVisual
function! gemini#SendVisualSelectionToChat() abort range
    let l:selected_text = join(getline(a:firstline, a:lastline), "\n")
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
            echo "  - ID: " . l:id[:7] . " (Buffer: " . bufnr2name(l:bufnr) . ")"
        else
            echo "  - ID: " . l:id[:7] . " (Buffer: NOT ACTIVE)"
        endif
    endfor
    echo "Current Session: " . (empty(g:gemini_current_chat_id) ? "None" : g:gemini_current_chat_id[:7])
endfunction

" Command handler for :GeminiChatSwitch
function! gemini#SwitchChat(session_id_prefix) abort
    " Find the full ID based on the prefix
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
        normal! G " Go to end of buffer
    else
        echoerr "Chat buffer not active for session: " . l:full_id[:7] . ". Try restarting session if needed."
        " Optionally, you could add logic here to try to reload history if persistence is implemented.
    endif
endfunction

" Command handler for :GeminiChatEnd
function! gemini#EndChat(session_id_prefix) abort
    " Find the full ID based on the prefix
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
                exe 'bdelete! ' . l:bufnr " Close and delete the buffer
            endif
            call remove(g:gemini_chat_buffers, l:full_id) " Remove from global map
        endif
        if g:gemini_current_chat_id ==# l:full_id
            let g:gemini_current_chat_id = '' " Clear current session if it was the one being ended
        endif
        echo l:result.message
    else
        echoerr "Failed to end chat: " . l:result.error
    endif
endfunction
