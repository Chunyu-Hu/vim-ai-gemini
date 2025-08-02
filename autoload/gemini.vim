" autoload/gemini.vim
" Contains most of the Vimscript logic, interaction with Python,
" and UI-related functions for the Gemini AI plugin.

" ============================================================================
" Global State Variables for Chat Sessions
" ============================================================================

" Global variable to store the current active chat session ID.
" Managed by gemini#StartChat and gemini#SwitchChat.
if !exists('g:gemini_current_chat_id')
    let g:gemini_current_chat_id = -1
endif
if !exists('g:gemini_chat_winid')
    let g:gemini_chat_winid = 0
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

let g:model_info = "(model: " . g:gemini_default_model . ")..."

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

    let l:original_win = win_getid()
    let l:original_buf = bufnr('%')
    let l:original_pos = getpos('.')

    let l:target_bufnr = g:gemini_ask_display_bufnr

    " Check if the buffer exists and is valid.
    if l:target_bufnr == -1 || !bufexists(l:target_bufnr) || bufname(l:target_bufnr) !=# '[GeminiAsk Result]' || !buflisted(l:target_bufnr)
        let l:bufname = '[GeminiAsk Result]'
        " Always create in a vertical split.
        exe 'silent! keepjumps rightbelow vnew'
        exe 'silent! file ' . l:bufname
        let l:target_bufnr = bufnr('%')
        if l:target_bufnr == -1
            let l:target_bufnr = bufnr('%')
            if bufname(l:target_bufnr) !=# l:bufname
                echoerr "Gemini.vim: Internal error - could not create unique ask buffer."
                return -1
            endif
        endif

        call setbufvar(l:target_bufnr, '&buftype', 'nofile')
        "call setbufvar(l:target_bufnr, '&bufhidden', 'delete')
        call setbufvar(l:target_bufnr, '&filetype', a:filetype_arg)

        " Store the new bufnr globally.
        let g:gemini_ask_display_bufnr = l:target_bufnr
        exe 'buffer ' . l:target_bufnr
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
    call win_gotoid(l:original_win)
    exe 'buffer ' . l:original_buf
    call setpos('.', l:original_pos)
endfunction

" Function to save the current GeminiAsk chat buffer to a log file.
" The file name will be gemini-ask.YYYY-MM-DD_HH-MM-SS.log
function! gemini#SaveAskLog() abort
    " Check if logging is enabled (optional, but good practice if you have a g:gemini_ask_log_enabled for this specific feature)
    " The original config only had g:gemini_ask_log_enabled for the "file logging" not "chat save"
    " For now, we'll assume this save function is always available if called.

    " 1. Validate the GeminiAsk display buffer
    if !exists('g:gemini_ask_display_bufnr') || g:gemini_ask_display_bufnr == -1
        echoerr "Gemini.vim: No active GeminiAsk Result buffer to save."
        return
    endif

    let l:target_bufnr = g:gemini_ask_display_bufnr
    if !bufexists(l:target_bufnr) || bufname(l:target_bufnr) !=# '[GeminiAsk Result]'
        echoerr "Gemini.vim: GeminiAsk Result buffer not found or is invalid."
        return
    endif

    " Get all lines from the target buffer
    let l:lines = getbufline(l:target_bufnr, 1, '$')

    " If the buffer is empty, there's nothing to save
    if empty(l:lines)
        echo "Gemini.vim: GeminiAsk Result buffer is empty. Nothing to save."
        return
    endif

    " 2. Prepare the log directory
    " Ensure g:gemini_ask_log_dir is set (it should be from your config snippet)
    if !exists('g:gemini_ask_log_dir') || empty(g:gemini_ask_log_dir)
        echoerr "Gemini.vim: Log directory (g:gemini_ask_log_dir) is not set. Cannot save log."
        return
    endif

    let l:log_dir = g:gemini_ask_log_dir

    " Create the directory if it doesn't exist
    if !isdirectory(l:log_dir)
        try
            call mkdir(l:log_dir, 'p') " 'p' creates parent directories
        catch /E/
            echoerr "Gemini.vim: Could not create log directory '" . l:log_dir . "': " . v:exception
            return
        endtry
    endif

    " 3. Generate the unique filename
    " Format: gemini-ask.YYYY-MM-DD_HH-MM-SS.log
    let l:date_str = strftime('%Y-%m-%d_%H-%M-%S')
    let l:filename = 'gemini-ask.' . l:date_str . '.log'
    let l:full_path = l:log_dir . '/' . l:filename

    " 4. Save the content to the file
    try
        call writefile(l:lines, l:full_path, 'w') " 'w' to write (overwrite if exists, but filename is unique)
        echo "GeminiAsk chat log saved to: " . l:full_path
    catch /E/
        echoerr "Gemini.vim: Failed to save log to '" . l:full_path . "': " . v:exception
    endtry
endfunction


" Command handler for :GeminiAsk
function! gemini#Ask(...) abort
    let l:prompt = ''
    if a:0 > 0
        let l:prompt = join(a:000, ' ')
    else
        let l:prompt = input("Ask Gemini (model:" . g:gemini_default_model . "): ")
        echo '\n'
    endif

    if empty(l:prompt)
        echo "Canceled or empty prompt."
        return
    endif

    echo "Asking Gemini..."
    let l:response = gemini#GenerateContent(l:prompt, g:gemini_default_model)

    if !empty(l:response) " Update the Ask buffer with user's prompt and Gemini's response.
        echo "Gemini response received."
        call s:update_ask_buffer(l:prompt, l:response, 'markdown')
    else
        echoerr "Gemini did not return a response."
    endif
endfunction

" Description: Applies configured word replacements to a given string.
"              It uses the global dictionary g:gemini_replacements, which
"              should map old words to new words (e.g., {'foo': 'bar'}).
" Arguments:
"   a:text: The string to which the replacements will be applied.
" Returns:
"   The processed string with replacements applied, or the original string
"   if g:gemini_replacements is not defined or is not a dictionary.
" ==============================================================================
function! gemini#ApplyWordReplacements(text) abort
    " Create a temporary variable to hold the processed text.
    " Initialize it with the input argument.
    let l:processed_text = a:text

    " Check if the global replacement dictionary exists and is actually a dictionary.
    if exists('g:gemini_replacements') && type(g:gemini_replacements) == v:t_dict
        " Iterate over each old word (key) in the g:gemini_replacements dictionary.
        for l:old_word in keys(g:gemini_replacements)
            let l:new_word = g:gemini_replacements[l:old_word]

            " Create a regex pattern for whole word replacement.
            " '\V' makes subsequent characters non-magic, so escape() only needs to handle '\'
            " '\<' and '\>' are word boundaries for whole word matching
            " escape(l:old_word, '\') ensures that special regex characters in l:old_word
            " are treated literally.
            let l:pattern = '\V\<' . escape(l:old_word, '\') . '\>'

            " Perform the global replacement within l:processed_text.
            " 'g' flag ensures all occurrences are replaced.
            let l:processed_text = substitute(l:processed_text, l:pattern, l:new_word, 'g')
        endfor
    endif

    " Return the processed text (or the original text if no replacements were applied).
    return l:processed_text
endfunction

" Command handler for :GeminiAskVisual
function! gemini#AskVisual(...) abort range
    let l:current_win_id = win_getid()
    let l:original_buf = bufnr('%')
    let l:original_pos = getpos('.')

    let l:start_line = line("'<")
    let l:end_line = line("'>")
    let l:selected_code = join(getline(l:start_line, l:end_line), "\n")

    " Fallback to clipboard registers if unnamed is empty (e.g., another yank happened or no selection).
    "if empty(l:selected_code) && has('clipboard')
        "let l:temp_clipboard_content_star = getreg('*')
        "if !empty(l:temp_clipboard_content_star)
            "let l:selected_code = l:temp_clipboard_content_star
        "else
            "let l:temp_clipboard_content_plus = getreg('+')
            "if !empty(l:temp_clipboard_content_plus)
                "let l:selected_code = l:temp_clipboard_content_plus
            "endif
        "endif
    "endif

    if a:0 > 0
        let l:user_prompt_text = join(a:000, ' ')
    else
        let l:user_prompt_text = input("Ask Gemini(" . g:gemini_default_model . "): ")
        echo '\n'
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
    let l:processed_lines = gemini#ApplyWordReplacements(l:combined_prompt_for_gemini)
    echo "Sending combined prompt and code to Gemini " . g:model_info
    
    " Call Python to generate content using the combined prompt.
    let l:response = gemini#GenerateContent(l:processed_lines, g:gemini_default_model)

    if !empty(l:response)
        " Update the Ask buffer with the *full combined prompt* (including code) and Gemini's response.
        echo "Gemini response received."
        call s:update_ask_buffer(l:processed_lines, l:response, 'markdown')
    else
        echoerr "Gemini did not return a response."
    endif

    " Return to original buffer and position.
    call win_gotoid(l:current_win_id)
    "exe l:original_win . 'wincmd w'
    exe 'buffer ' . l:original_buf
    call setpos('.', l:original_pos)
endfunction


" Command handler for :GeminiGenerateVisual
function! gemini#SendVisualSelection() abort range
    let l:lastline = line("'>")
    let l:selected_text = join(getline(a:firstline, l:lastline), "\n")
    if a:0 > 0
        let l:user_prompt_text = join(a:000, ' ')
    else
        let l:user_prompt_text = input("Ask Gemini(" . g:gemini_default_model . "):")
        echo '\n'
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
    let l:processed_lines = gemini#ApplyWordReplacements(l:combined_prompt_for_gemini)
    echo "Sending selected text to Gemini " . g:model_info

    let l:response = gemini#GenerateContent(l:processed_lines, g:gemini_default_model)

    if !empty(l:response)
        " Keeping s:display_in_new_buffer for these as they are transient.
        call s:update_ask_buffer(l:processed_lines, l:response, 'markdown')
        echo "Gemini response received in new buffer."
    else
        echoerr "Gemini did not return a response."
    endif
endfunction

" Command handler for :GeminiGenerateBuffer
function! gemini#SendBuffer() abort
    let l:buffer_content = join(getline(1, '$'), "\n")
    if a:0 > 0
        let l:user_prompt_text = join(a:000, ' ')
    else
        let l:user_prompt_text = input("Ask Gemini: ")
        echo '\n'
    endif

    " Simplify the combined prompt: just concatenate, no markdown fences.
    let l:combined_prompt_for_gemini = ''
    if !empty(l:user_prompt_text)
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . l:user_prompt_text
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . "\n\n"
    endif
    if !empty(l:buffer_content)
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . "\n"
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . l:buffer_content . "\n"
    endif
    echo "Sending entire buffer to Gemini" . g:model_info
    let l:processed_lines = gemini#ApplyWordReplacements(l:combined_prompt_for_gemini)
    let l:response = gemini#GenerateContent(l:processed_lines, g:gemini_default_model)

    if !empty(l:response)
        " Keeping s:display_in_new_buffer for these as they are transient.
        call s:update_ask_buffer(l:processed_lines, l:response, 'markdown')
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

    let l:original_win = win_getid()
    let l:original_buf = bufnr('%')
    let l:original_pos = getpos('.')

    " Use :vnew to create a new vertical split for the response.
    exe 'silent! keepjumps rightbelow vnew'
    
    " Set buffer options for the response buffer.
    setlocal buftype=nofile
    setlocal bufhidden=delete
    exe 'setlocal filetype=' . a:filetype_arg
    call append(0, split(a:content, "\n"))
    normal! gg

    call s:apply_gemini_highlights()

    " Return to original buffer and position.
    call win_gotoid(l:original_win)
    exe 'buffer ' . l:original_buf
    call setpos('.', l:original_pos)
endfunction

let s:popup_all_lines = []
let s:popup_start_line = 0
let g:popup_bufnr = -1
function! s:UpdatePopup()
  " Extract a 20-line slice from popup_all_lines starting at popup_start_line
  let slice = s:popup_all_lines[s:popup_start_line : s:popup_start_line + 19]
  call popup_settext(g:gemini_popup_id, slice)
endfunction

function! s:PopupFilter(id, key)
  if a:key ==# 'q'
    " Close popup and return to previous window
    call popup_close(a:id)
    call win_gotoid(g:previous_winid)
    return 1

  elseif a:key ==# 'j'
    " Scroll down if more lines are below
    if s:popup_start_line + 20 < len(s:popup_all_lines)
      let s:popup_start_line += 1
      call s:UpdatePopup()
    endif
    return 1

  elseif a:key ==# 'k'
    " Scroll up if not at top
    if s:popup_start_line > 0
      let s:popup_start_line -= 1
      call s:UpdatePopup()
    endif
    return 1
  elseif a:key ==# 'v' || a:key ==# 'V' || a:key ==# 'y'
    let popup_height = winheight(a:id)
    let end_index = min([s:popup_start_line + popup_height, len(s:popup_all_lines)])
    let visible_lines = s:popup_all_lines[s:popup_start_line : end_index - 1]
    let content_to_copy = join(visible_lines, "\n")
    try
      let @+ = content_to_copy
      let @* = content_to_copy
    catch /E291/:
    endtry
    let @" = content_to_copy
    echo printf("%d line(s) copied to register.", len(visible_lines))
    return 1
  endif
  return 0
endfunction

function! s:ShowPopupResponse(text) abort
  let s:popup_all_lines = split(a:text, "\n")
  let g:previous_winid = win_getid()

  " Save a copy to the chat buffer, so use can copy it and record chat history
  call s:update_ask_buffer('', a:text, 'markdown')

  " Close old popup if visible
  if exists('g:gemini_popup_id')
    call popup_close(g:gemini_popup_id)
    let g:gemini_popup_id = -1
  endif
  if g:gemini_popup_id == -1 || popup_getpos(g:gemini_popup_id) == {}
      let g:gemini_popup_id = popup_create(s:popup_all_lines, {
          \ 'padding': [1,2,1,1],
          \ 'pos': 'topleft',
          \ 'line': 10,
          \ 'col': 10,
          \ 'maxwidth': 120,
          \ 'minheight': 5,
          \ 'maxheight': 20,
          \ 'minwidth': 60,
          \ 'zindex': 10,
          \ 'mapping': v:true,
          \ 'wrap': v:true,
          \ 'scrollbar': 1,
          \ 'filter': function('s:PopupFilter', {}),
          \ 'highlight': 'PopupColorfulBody',
          \ 'border': ['single', 'PopupColorfulBorder'],
          \ })

    "call s:HighlightPopup(g:gemini_popup_id)
    " Jump cursor to popup window
    call win_gotoid(g:gemini_popup_id)
    " Map 'q' inside popup to close it and jump back to previous window
    call win_execute(g:gemini_popup_id, printf(
    \ 'nnoremap <buffer> q :call popup_close(%d) \| call win_gotoid(%d)<CR>',
    \ g:gemini_popup_id, g:previous_winid))

  endif

  " No popup_getwin / win_execute in Vim — skip scroll-to-bottom
endfunction

" Helper function to display the Gemini response
function! gemini#_DisplayResponse(response_text) abort
    let l:display_mode = get(g:, 'gemini_send_visual_selection_display_mode', 'new_buffer')
    let l:updated_response_text = "🌈" . a:response_text . "💖"
    if l:display_mode ==# 'new_buffer'
        " Open a new scratch buffer to display the response
        execute 'silent! rightbelow new GeminiResponse'
        setlocal buftype=nofile
        setlocal bufhidden=wipe
        setlocal nobuflisted
        "setlocal nomodifiable
        setlocal nowrap
        call setline(1, split(l:updated_response_text, "\n"))
        normal! Gzt
        " Set filetype if it looks like code, or just for general text
        if a:response_text =~? '\(^\s*function\|\<def\s\+class\|\<import\s\+.*\)'
            " Basic heuristic, might need refinement
            execute 'setfiletype ' . get(g:, 'gemini_response_filetype', 'markdown')
        else
            setfiletype markdown " Default to markdown for better readability
        endif
        normal! gg
    elseif l:display_mode ==# 'popup'
        " Use popup_atcursor for a floating window
        " Clear existing highlights (useful if running the script multiple times)
        silent! hi clear PopupColorfulBody
        silent! hi clear PopupColorfulBorder
        silent! hi clear PopupColorfulTitle

        " Define highlight group for the popup body (text and background)
        " ctermfg/bg for terminal Vim, guifg/bg for GUI Vim
        exec 'hi PopupColorfulBody ctermfg=17 ctermbg=24 guifg=#0088BB guibg=#ADD8E6'

        " Define highlight group for the popup border
        exec 'hi PopupColorfulBorder cterm=bold ctermfg=198 guifg=#FF1493'

        " Define highlight group for the popup title (optional, using standard Title is also fine)
        exec 'hi PopupColorfulTitle cterm=bold ctermfg=230 ctermbg=202 guifg=#FFFFFF guibg=#FFFF88'
        call s:ShowPopupResponse(a:response_text)
		return

        let g:gemini_popup_id = popup_atcursor(split(l:updated_response_text, "\n"), {
              \ 'title': 'Gemini Response',
              \ 'line': 1,
              \ 'col': 1,
              \ 'width': winwidth(0) * 2 / 3,
              \ 'height': winheight(0) * 2 / 3,
              \ 'border': ['single', 'PopupColorfulBorder'],
              \ 'maxwidth': 80,
              \ 'minheight': 5,
              \ 'maxheight': 20,
              \ 'minwidth': 60,
              \ 'zindex': 10,
              \ 'mapping': v:true,
              \ 'wrap': v:true,
              \ 'scrollbar': 1,
              \ 'filter': function('s:PopupFilter'),
              \ 'close': 'none',
              \ 'moved': [0,0,0],
              \ 'highlight': 'PopupColorfulBody',
              \ })
        " Jump cursor to popup window
        call win_gotoid(g:gemini_popup_id)
        " Map 'q' inside popup to close it and jump back to previous window
        call win_execute(g:gemini_popup_id, printf(
             \ 'nnoremap <buffer> q :call popup_close(%d) \| call win_gotoid(%d)<CR>',
             \ g:gemini_popup_id, g:previous_winid))
    elseif l:display_mode ==# 'insert'
        " Insert the response directly into the buffer
        let l:current_pos = getpos('.')
        call append(line('.'), split(a:response_text, "\n"))
        call setpos('.', l:current_pos) " Restore cursor position
        echomsg "Gemini response inserted."
    elseif l:display_mode ==# 'echomsg'
        echomsg "Gemini Response: " . a:response_text
    else
        echomsg "Unknown display mode: " . l:display_mode
        echomsg "Gemini Response: " . a:response_text
    endif
endfunction


" Main function to send visual selection
function! gemini#SendVisualSelection() abort range
    " Ensure there is a visual selection. 'range' itself indicates lines are selected.
    " For character-wise selection, '< and '> marks can be used more precisely.
    " However, `getline(a:firstline, a:lastline)` will always get full lines.
    " If you want *exact* character-wise selection, you'd need to yank it first:
    " let l:selected_text = getreg('"')
    " But for LLM tasks, often line-wise is sufficient.

    let l:startline = line("'<")
    let l:endline = line("'>")

    " Check if a valid range was selected
    if l:startline == 0 || l:endline == 0
        echohl ErrorMsg
        echomsg "No visual selection found. Please select text visually (v, V, <C-v>) first."
        echohl None
        return
    endif

    let l:selected_text = join(getline(l:startline, l:endline), "\n")

    if a:0 > 0
        let l:user_prompt_text = join(a:000, ' ')
    else
        let l:user_prompt_text = input("Ask Gemini(" . g:gemini_default_model . "): ")
        echo '\n'
    endif

    " Simplify the combined prompt: just concatenate, no markdown fences.
    let l:combined_prompt_for_gemini = ''
    if !empty(l:user_prompt_text)
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . l:user_prompt_text
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . "\n\n"
    endif
    if !empty(l:selected_text)
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . "\n"
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . l:selected_text . "\n"
    endif
    let l:processed_lines = gemini#ApplyWordReplacements(l:combined_prompt_for_gemini)

    " Apply the prompt template
    let l:final_prompt = substitute(g:gemini_send_visual_selection_prompt_template, '{text}', l:processed_lines, 'g')


    " Add an undo point before potentially changing the buffer or opening a new one
    " if g:gemini_send_visual_selection_display_mode ==# 'insert'
    " This is handled by the calling command if you map it to `:call`
    " endif

    echo "Sending selected text to Gemini (model: " . g:gemini_default_model . ")..."

    " Use a try-catch block for error handling
    try
        let l:response = gemini#GenerateContent(l:final_prompt, g:gemini_default_model)

        if empty(l:response)
            echohl WarningMsg
            echomsg "Gemini returned an empty response."
            echohl None
        else
            call gemini#_DisplayResponse(l:response)
            echomsg "Gemini response received."
        endif

    catch /.*/
        echohl ErrorMsg
        echomsg "Error communicating with Gemini: " . v:exception
        echohl None
    endtry
endfunction

" Map it for convenience
" Recommended mapping: enter visual mode, select text, then press <leader>gv
" Or for line-wise visual mode: V, select lines, <leader>gv
xnoremap <leader>gv :<C-u>call gemini#SendVisualSelection()<CR>


" Command handler for :GeminiReplaceVisual (in-place replacement)
function! gemini#SendVisualSelectionReplace(...) abort range
    " Save current view/cursor position (optional, good for undo/inspect).
    normal! gv"ay

    " Get the selected text.
    let l:start_line = line("'<")
    let l:end_line = line("'>")
    let l:selected_text = join(getline(l:start_line, l:end_line), "\n")

    if a:0 > 0
        let l:user_prompt_text = join(a:000, ' ')
    else
        let l:user_prompt_text = input("Ask Gemini: ")
        echo '\n'
    endif

    " Simplify the combined prompt: just concatenate, no markdown fences.
    let l:combined_prompt_for_gemini = ''
    if !empty(l:user_prompt_text)
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . l:user_prompt_text
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . "\n\n"
    endif
    if !empty(l:selected_text)
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . "\n"
        let l:combined_prompt_for_gemini = l:combined_prompt_for_gemini . l:selected_text . "\n"
    endif
    let l:processed_lines = gemini#ApplyWordReplacements(l:combined_prompt_for_gemini)

    echo "Sending selected text to Gemini for replacement" . g:model_info

    " Call the Python function.
    let l:response = gemini#GenerateContent(l:processed_lines, g:gemini_default_model)

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

" Script-local function to setup the global winid when the chat window closes.
function! s:setup_chat_winid(bufname) abort
    if exists('g:gemini_chat_winid') && g:gemini_chat_winid == 0
		let l:origin_winid = win_getid()
        exe 'silent! keepjumps rightbelow vnew ' . a:bufname
        let g:gemini_chat_winid = win_getid()
        call s:set_buffer_options()
        call win_gotoid(l:origin_winid)
    endif
endfunction

function! s:chat_winclose_handler(closed_win_id) abort
    if a:closed_win_id == g:gemini_chat_winid
        let g:gemini_chat_winid = 0
    endif
endfunction

augroup GeminiWinHandlers
    " Clear existing autocmds for this augroup
    autocmd!
    autocmd WinClosed * call s:chat_winclose_handler(expand('<amatch>'))
augroup END


" Script-local function to clear the global winid when the chat window closes.
function! s:clear_chat_winid() abort
    if exists('g:gemini_chat_winid') && g:gemini_chat_winid != 0 && win_id2win(g:gemini_chat_winid) == 0
        unlet g:gemini_chat_winid
        let g:gemini_chat_winid = 0
        " Note: Session buffers might still exist, just not displayed in a dedicated window.
        " If you want to auto-delete them too, you'd iterate `getbufinfo()` and `bdelete`
        " buffers matching a pattern, but this is usually not desired as it deletes history.
    endif
endfunction


" Helper function to set buffer options for a Gemini chat buffer
function! s:set_buffer_options() abort
    setlocal buftype=nofile     " Not backed by a file
    "setlocal nobuflisted        " Don't show in :ls or buffer lists (unless you want them visible)
    setlocal nomodifiable       " Prevent user from typing directly
    setlocal nowrap             " Don't wrap lines
    setlocal nonumber           " No line numbers
    setlocal norelativenumber   " No relative line numbers
    setlocal nospell            " No spell check
    setlocal foldcolumn=0       " No fold column
    setlocal signcolumn=no      " No sign column
    setlocal cursorline         " Highlight current line (optional)
    setlocal filetype=markdown  " Good for AI responses.
    " Mark this buffer as having its setup done
    call setbufvar(bufnr('%'), 'gemini_chat_buf_setup_done', 1)
endfunction

function! s:get_chat_buffer(session_id, create_if_not_exists) abort
    let l:bufname = '[Gemini Chat] ' . a:session_id[:7] " Use a prefix for buffer name.
    call s:setup_chat_winid(l:bufname)
    " Check if buffer for this session ID already exists and is listed.
    if has_key(g:gemini_chat_buffers, a:session_id) && buflisted(get(g:gemini_chat_buffers, a:session_id, -1))
        return g:gemini_chat_buffers[a:session_id]
    endif

    " If not found, create if requested.
    if a:create_if_not_exists
            " Use :vnew to create an empty buffer in a new vertical split, then :file to name it.
            "exe 'silent! keepjumps rightbelow vnew'
        try
            call win_gotoid(g:gemini_chat_winid)
            exe 'silent enew'
            exe 'silent file ' . l:bufname
            let l:bufnr = bufnr('%')
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
                "call setbufvar(l:bufnr, '&bufhidden', 'delete')   " Deletes buffer when no windows show it.
                call setbufvar(l:bufnr, '&filetype', 'markdown')  " Sets syntax highlighting.
                
                " Store session ID in buffer-local variable for context.
                call setbufvar(l:bufnr, 'gemini_session_id', a:session_id)
                " Store bufnr in global map.
                let g:gemini_chat_buffers[a:session_id] = l:bufnr
                call append(0, ["Gemini Chat Session: " . a:session_id, "buffer ". l:bufnr, "Waiting for Gemini response...", ""])
                return l:bufnr
            endif
        catch
            echo "DEBUG: Error during buffer creation in s:get_chat_buffer: " . v:exception
            let l:bufnr = -1
        endtry
    endif
    return -1
endfunction

" Function to send content of multiple files to chat
function! gemini#SendFilesToChat(file_paths) abort
    let l:combined_content = []
    let l:found_files = 0

    for l:filepath in a:file_paths
        let l:expanded_filepath = fnamemodify(l:filepath, ':p')
        if filereadable(l:expanded_filepath)
            let l:found_files += 1
            call add(l:combined_content, printf("--- Content of %s ---", fnamemodify(l:expanded_filepath, ':t')))
            call extend(l:combined_content, readfile(l:expanded_filepath))
            call add(l:combined_content, "")
        else
            echow printf("File not found or unreadable: %s", l:filepath)
        endif
    endfor

    if l:found_files > 0
        let l:input_str = input("Enter your prompt: ")
        let l:buffer_content = join(l:combined_content, "\n")
		echo "\n"
        if !empty(l:input_str)
            let l:buffer_content = l:input_str . "\n" . l:buffer_content
        endif
        let l:processed_lines = gemini#ApplyWordReplacements(l:buffer_content) " Assuming this exists
        call gemini#SendMessage(l:processed_lines) " Assuming this exists
        echo printf("Sent content of %d file(s) to chat.", l:found_files)
    else
        echo "No valid files found to send."
    endif
endfunction


" New function: Send files based on arguments, or prompt if no arguments
function! gemini#SendFilesOrPrompt(...) abort
    let l:file_paths_to_send = []

    if a:0 > 0
        " Arguments were provided, treat them as file paths
        let l:file_paths_to_send = a:000
    else
        " No arguments, prompt the user for file paths
        let l:input_str = input("Enter file paths (space-separated): ")

        if empty(l:input_str)
            echo "Canceled or no file paths entered."
            return
        endif

        " Split the input string by spaces to get a list of paths
        let l:file_paths_to_send = split(l:input_str, ' ')
    endif

    " Call the existing function to handle the actual sending
    call gemini#SendFilesToChat(l:file_paths_to_send)
endfunction

" Function to save a Gemini chat session buffer to a log file.
" The file name will be gemini-chat.$(session_id).YYYY-MM-DD_HH-MM-SS.log
"
" @param a:session_id (optional string): The ID of the session to save.
"                                      If empty, saves the current buffer's session.
function! gemini#SaveChatLog(...) abort
    let l:session_id = v:null

    " Check the number of arguments passed
    if a:0 == 1
        " If one argument is provided, use it as the session_id
        let l:session_id = a:[0]
    elseif a:0 > 1
        " Handle cases where too many arguments are passed (optional: throw an error)
        echohl ErrorMsg | echo "Error: gemini#SaveChatLog accepts zero or one argument, but " . a:0 . " were given." | echohl None
        return
    else
		if (g:gemini_current_chat_id > 0)
            let l:session_id = g:gemini_current_chat_id
        endif
    endif

    " Determine which buffer to save
    if !empty(l:session_id)
        " User specified a session ID
        if !has_key(g:gemini_chat_buffers, l:session_id)
            echoerr "Gemini.vim: Session ID '" . l:session_id . "' not found in active chat buffers."
            return
        endif
        let l:target_bufnr = g:gemini_chat_buffers[l:session_id]
        let l:current_session_id = l:session_id
    else
        " No session ID specified, try to save the current buffer if it's a chat session.
        let l:current_bufnr = bufnr('%')
        if bufexists(l:current_bufnr) && getbufvar(l:current_bufnr, '&buftype') ==# 'nofile' && bufname(l:current_bufnr) =~# '^\[Gemini Chat\]'
            " It looks like a chat buffer, try to get the session ID from its buffer variable.
            if exists('b:gemini_session_id') && !empty(b:gemini_session_id)
                let l:target_bufnr = l:current_bufnr
                let l:current_session_id = b:gemini_session_id
            else
                echoerr "Gemini.vim: Current buffer is a chat buffer, but 'b:gemini_session_id' is not set. Cannot determine session to save."
                return
            endif
        else
            echoerr "Gemini.vim: Not currently in a Gemini chat buffer. Please specify a session ID or switch to a chat buffer."
            return
        endif
    endif

    " Final validation of the determined buffer
    if l:target_bufnr == -1 || !bufexists(l:target_bufnr) || empty(l:current_session_id)
        echoerr "Gemini.vim: Could not identify a valid chat session buffer to save."
        return
    endif

    " Get all lines from the target buffer
    let l:lines = getbufline(l:target_bufnr, 1, '$')

    " Remove the "Waiting for Gemini response..." line if it's the last one
    if !empty(l:lines) && l:lines[-1] =~# '^Waiting for Gemini response\.\.\.$'
        call remove(l:lines, -1)
        " Also remove the blank line before it if it exists and there's content before that
        if len(l:lines) > 0 && empty(l:lines[-1]) && len(l:lines) > 1
             call remove(l:lines, -1)
        endif
    endif


    " If the buffer is empty after cleaning, there's nothing to save
    if empty(l:lines)
        echo "Gemini.vim: Chat session buffer is empty. Nothing to save."
        return
    endif

    " 2. Prepare the log directory
    if !exists('g:gemini_ask_log_dir') || empty(g:gemini_ask_log_dir)
        echoerr "Gemini.vim: Log directory (g:gemini_ask_log_dir) is not set. Cannot save log."
        return
    endif

    let l:log_dir = g:gemini_ask_log_dir

    " Create the directory if it doesn't exist
    if !isdirectory(l:log_dir)
        try
            call mkdir(l:log_dir, 'p')
        catch /E/
            echoerr "Gemini.vim: Could not create log directory '" . l:log_dir . "': " . v:exception
            return
        endtry
    endif

    " 3. Generate the unique filename
    " Format: gemini-chat.SESSION_ID_SHORT.YYYY-MM-DD_HH-MM-SS.log
    let l:date_str = strftime('%Y-%m-%d_%H-%M-%S')
    " Use a short version of the session ID for the filename
    let l:session_id_short = l:current_session_id[:7]
    let l:filename = 'gemini-chat.' . l:session_id_short . '.' . l:date_str . '.log'
    let l:full_path = l:log_dir . '/' . l:filename

    " 4. Save the content to the file
    try
        call writefile(l:lines, l:full_path, 'w')
        echo "GeminiAsk chat session '" . l:session_id_short . "' saved to: " . l:full_path
    catch /E/
        echoerr "Gemini.vim: Failed to save chat log to '" . l:full_path . "': " . v:exception
    endtry
endfunction

" Function called by the timer to auto-save all active chat sessions.
function! gemini#AutoSaveAllChatSessions() abort
    if !g:gemini_ask_auto_save_chat_enabled
        " If auto-save gets disabled mid-run, stop the timer.
        call gemini#StopChatAutoSaveTimer()
        return
    endif

    " Iterate through all known chat buffers and save them.
    " g:gemini_chat_buffers is expected to be a dictionary: {session_id: bufnr}
    if exists('g:gemini_chat_buffers') && type(g:gemini_chat_buffers) == v:t_dict
        for l:session_id in keys(g:gemini_chat_buffers)
            " Check if the buffer still exists and is valid before saving
            let l:bufnr = g:gemini_chat_buffers[l:session_id]
            if bufnr(l:bufnr) == l:bufnr && bufexists(l:bufnr) && bufname(l:bufnr) =~# '^\[Gemini Chat\]'
                " Call the existing save function for each session ID
                " Use a try-catch block to prevent one session's error from stopping others
                try
                    call gemini#SaveChatLog(l:session_id)
                catch /E/
                    " Log the error but don't stop the auto-save process
                    echomsg "Gemini.vim: Error auto-saving session '" . l:session_id . "': " . v:exception
                endtry
            else
                " Clean up invalid entries from g:gemini_chat_buffers
                unlet g:gemini_chat_buffers[l:session_id]
            endif
        endfor
    endif
endfunction

" Function to start the auto-save timer.
function! gemini#StartChatAutoSaveTimer() abort
    if !g:gemini_ask_auto_save_chat_enabled
        return "Auto-save is disabled."
    endif

    " Stop any existing timer first to prevent duplicates
    call gemini#StopChatAutoSaveTimer()

    " Start the new timer
    let g:gemini_ask_auto_save_chat_timer_id = timer_start(g:gemini_ask_auto_save_chat_interval_ms, 'gemini#AutoSaveAllChatSessions', {'repeat': -1})
    echomsg "Gemini.vim: Auto-saving of chat sessions enabled every " . (g:gemini_ask_auto_save_chat_interval_ms / 0) . " seconds."
    return g:gemini_ask_auto_save_chat_timer_id
endfunction

" Function to stop the auto-save timer.
function! gemini#StopChatAutoSaveTimer() abort
    if g:gemini_ask_auto_save_chat_timer_id != 0
        call timer_stop(g:gemini_ask_auto_save_chat_timer_id)
        let g:gemini_ask_auto_save_chat_timer_id = 0
        echomsg "Gemini.vim: Auto-saving of chat sessions stopped."
    endif
endfunction

" Ensure timer is started/stopped based on g:gemini_ask_auto_save_chat_enabled
" This part should be called once after plugin config is loaded,
" or whenever g:gemini_ask_auto_save_chat_enabled changes.
" A good place for this might be at the end of your main plugin file, or an autocommand.


" Command handler for :GeminiChatStart
function! gemini#StartChat() abort
    let l:result = s:call_python_and_parse_response(
                \ printf("gemini_api_handler.start_gemini_chat_session('%s')", g:gemini_api_key_source))

    if l:result.success
        let g:gemini_current_chat_id = l:result.session_id
        echo "New Gemini chat session started: " . g:gemini_current_chat_id[:7]
        " Create and switch to the new chat buffer.
        let l:original_winid = win_getid()
        if g:gemini_chat_winid == 0 || win_id2win(g:gemini_chat_winid) == 0
            exe 'silent! keepjumps rightbelow vnew'
            let g:gemini_chat_winid = win_getid()
        endif
        call win_gotoid(l:original_winid)
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
    let l:original_winid = win_getid()
    "if g:gemini_chat_winid == 0 || win_id2win(g:gemini_chat_winid) == 0
    "    exe 'silent! keepjumps rightbelow vnew'
    "    let g:gemini_chat_winid = win_getid()
    "endif
    let l:bufnr = s:get_chat_buffer(g:gemini_current_chat_id, 0)
    if l:bufnr == -1
        echoerr "Gemini Chat Error: The chat buffer for session '" . g:gemini_current_chat_id[:7] . "' is not active."
        echoerr "It might have been closed. Please start a new session with :GeminiChatStart, or try :GeminiChatSwitch " . g:gemini_current_chat_id[:7] . " if you believe it's still open."
        return
    endif

    " Setup an autocommand to clear g:gemini_chat_winid when this main chat window closes.
    let l:chat_bufnr_of_window = winbufnr(g:gemini_chat_winid)
    if l:chat_bufnr_of_window != -1
        exe 'autocmd BufUnload <buffer=' . l:chat_bufnr_of_window . '> ++once call s:clear_chat_winid()'
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
        call append(1, l:gemini_lines)
        
        
        setlocal nomodified
        echo "Gemini replied in session " . g:gemini_current_chat_id[:7]
        normal! G " Ensure cursor is at the end of the chat buffer.
    else
        echoerr "Gemini chat error: " . l:result.error
    endif

    call append(1 , l:user_lines)
    call s:apply_gemini_highlights()

    " Return to original buffer and position.
    " Return to the original window if desired
    if win_id2win(l:original_winid) != 0 && win_getid() != l:original_winid
        call win_gotoid(l:original_winid)
    endif
    exe 'buffer ' . l:current_buf
    call setpos('.', l:current_pos) " Restore cursor position.
endfunction

" Command handler for :GeminiChatSendVisual
function! gemini#SendVisualSelectionToChat(...) abort range
	let l:lastline = line("'>")
    let l:selected_code = join(getline(a:firstline, l:lastline), "\n")
    let l:user_prompt_text = ''

    if a:0 > 0
        let l:user_prompt_text = join(a:000, ' ')
    else
        let l:user_prompt_text = input("Ask Gemini(" . g:gemini_default_model . "):")
        " No need for echo '\n' here, input() handles its own output.
        " If you really want a newline *after* input clears, consider:
        echo ""
    endif

    let l:combined_prompt_for_gemini = ''

    if !empty(l:user_prompt_text)
        let l:combined_prompt_for_gemini .= l:user_prompt_text
    endif

    if !empty(l:selected_code)
        " Add separator only if both prompt and code exist, or if only code exists
        if !empty(l:user_prompt_text)
            let l:combined_prompt_for_gemini .= "\n\n" " Two newlines for separation
        endif

        " IMPORTANT: Wrap code in markdown fences for AI
        " You might want to auto-detect the language or make it configurable.
        " For now, let's assume a generic code block or add a placeholder.
        " Example: ```vim (or ```python, ```javascript, etc.)
        " Or just ``` for a generic block if language detection is hard.
        let l:combined_prompt_for_gemini .= "```\n" . l:selected_code . "\n```\n"
    endif

    echo "Sending selected text to Gemini " . g:model_info
    call gemini#SendMessage(l:combined_prompt_for_gemini)
endfunction

" Command handler for :GeminiChatSendBuffer
function! gemini#SendBufferToChat() abort
    let l:buffer_content = join(getline(1, '$'), "\n")
    let l:processed_lines = gemini#ApplyWordReplacements(l:buffer_content)
    call gemini#SendMessage(l:processed_lines)
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
    let l:original_winid = win_getid()
    let l:bufnr = s:get_chat_buffer(l:full_id, 0)
    if l:bufnr != -1
        call win_gotoid(g:gemini_chat_winid)
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
