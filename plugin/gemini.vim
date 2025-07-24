" plugin/gemini.vim
" Main entry point for the Gemini AI Vim plugin.
" Defines user commands and sets up initial environment.

" Prevent loading the plugin multiple times
if exists('g:loaded_gemini_plugin')
    finish
endif
let g:loaded_gemini_plugin = 1
if !exists('g:gemini_popup_id')
  let g:gemini_popup_id = -1
endif

" ============================================================================
" Global Configuration Variables (with default values)
" Users can override these in their .vimrc
" ============================================================================

" Source for the Gemini API key.
" Can be an environment variable name (e.g., 'GEMINI_API_KEY') or a file path
" (e.g., '~/.config/gemini.token' - expand('~') is used for user home).
" This variable is passed directly to the Python handler.
if !exists('g:gemini_api_key_source')
    let g:gemini_api_key_source = expand('~') . '/.config/gemini.token'
    " Alternatively, to use an environment variable (e.g., GEMINI_API_KEY):
    " let g:gemini_api_key_source = 'GEMINI_API_KEY'
endif

" Default Gemini model to use for single-turn content generation.
" Options: 'gemini-pro', 'gemini-1.5-flash', 'gemini-1.5-pro' (check Google AI documentation for latest)
if !exists('g:gemini_default_model')
    let g:gemini_default_model = 'gemini-pro'
endif

" ============================================================================
" Python Module Loading
" ============================================================================
" This section ensures the Python backend is loaded.
" Vim automatically adds the plugin's 'pythonx/' directory to sys.path
" when 'python3 import' is used in a plugin file.
if has('python3')
    try
        python3 import gemini_api_handler
    catch /Vim\%(Python\|Py3\):/
        echoerr "Gemini.vim: Failed to load Python module 'gemini_api_handler'."
        echoerr "Please ensure Python 3 is installed and 'google-generativeai' is pip installed."
        echoerr "Error details: " . v:exception
    endtry
endif

" ============================================================================
" Plugin Commands
" These commands call functions defined in autoload/gemini.vim
" ============================================================================

" --- Single-Turn Generation Commands ---

" Command: :GeminiAsk {prompt}
" Prompts the user for a question, sends it to Gemini, and displays response in new buffer.
command! -nargs=* GeminiAsk call gemini#Ask(<f-args>)

" Command: :GeminiGenerateVisual
" Sends the currently selected text (in visual mode) to Gemini.
" Response is displayed in a new scratch buffer.
command! -range=% GeminiGenerateVisual call gemini#SendVisualSelection()

" Command: :GeminiGenerateBuffer
" Sends the entire content of the current buffer to Gemini.
" Response is displayed in a new scratch buffer.
command! -nargs=0 GeminiGenerateBuffer call gemini#SendBuffer()

" Command: :GeminiReplaceVisual
" Sends the currently selected text (in visual mode) to Gemini and replaces
" the selection directly with Gemini's response.
command! -range=% GeminiReplaceVisual call gemini#SendVisualSelectionReplace()

" --- Chat Session Commands ---

" Command: :GeminiChatStart
" Starts a new Gemini chat session and opens a dedicated chat buffer.
command! -nargs=0 GeminiChatStart call gemini#StartChat()

" Command: :GeminiChatSend {message}
" Sends a message to the currently active Gemini chat session.
" The message and response are appended to the chat buffer.
command! -nargs=1 GeminiChatSend call gemini#SendMessage(<f-args>)

" Command: :GeminiChatSendVisual
" Sends the visually selected text as a message to the current chat session.
command! -range=% GeminiChatSendVisual call gemini#SendVisualSelectionToChat()

" Command: :GeminiChatSendBuffer
" Sends the entire current buffer content as a message to the current chat session.
command! -nargs=0 GeminiChatSendBuffer call gemini#SendBufferToChat()

" Command: :GeminiChatList
" Lists all active chat sessions.
command! -nargs=0 GeminiChatList call gemini#ListChats()

" Command: :GeminiChatSwitch {session_id_prefix}
" Switches to an existing chat session (e.g., using the first 8 chars of ID).
command! -nargs=1 -complete=customlist,gemini#_completion_chat_ids GeminiChatSwitch call gemini#SwitchChat(<f-args>)

" Command: :GeminiChatEnd {session_id_prefix}
" Ends and closes a specific chat session and its buffer.
command! -nargs=1 -complete=customlist,gemini#_completion_chat_ids GeminiChatEnd call gemini#EndChat(<f-args>)

command! GeminiPopupClose call popup_close(g:gemini_popup_id)

" ============================================================================
" Command-Line Tab Completion Functions
" ============================================================================

" Provides completion for available Gemini models (if you expand GeminiAsk to take a model argument)
function! gemini#_completion_models(arglead, cmdline, cursorpos) abort
    return join(['gemini-pro', 'gemini-1.5-flash', 'gemini-1.5-pro'], "\n")
endfunction

" Provides completion for active chat session IDs (first 8 characters)
function! gemini#_completion_chat_ids(arglead, cmdline, cursorpos) abort
    let l:ids = []
    for l:id in keys(g:gemini_chat_buffers)
        call add(l:ids, l:id[:7]) " Only show prefix
    endfor
    return join(l:ids, "\n")
endfunction
