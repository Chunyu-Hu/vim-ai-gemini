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

if !exists('g:gemini_new_window_command')
    let g:gemini_new_window_command = 'rightbelow vnew'
endif

" ==============================================================================
"                           Chat Formatting Configuration
" ==============================================================================
" Set to 1 to enable timestamps before chat messages (e.g., [YYYY-MM-DD HH:MM:SS])
" Set to 0 to disable timestamps.
if !exists('g:chat_timestamp_enabled')
    let g:chat_timestamp_enabled = 0
endif

" Customize the role name for user messages.
" Default: 'User'
if !exists('g:chat_user_role_name')
    let g:chat_user_role_name = 'User'
endif

" Customize the role name for Gemini (AI) messages.
" Default: 'Gemini'
if !exists('g:chat_gemini_role_name')
    let g:chat_gemini_role_name = 'Gemini'
endif

" Customize the marker that appears before the role name.
" Default: '#### ' (note the space at the end)
" Example: To get '### Tom:', set this to '###'
" Example: To get '--- Tom:', set this to '--- '
if !exists('g:chat_role_prefix_marker')
    let g:chat_role_prefix_marker = '#### '
endif

" Customize the suffix that appears after the role name.
" Default: ':' (note the space if you want one after the colon)
" Example: To get 'Tom ->', set this to ' ->'
if !exists('g:chat_role_prompt_suffix')
    let g:chat_role_prompt_suffix = ':'
endif

" Define the overall style of the chat message prefix.
" Use placeholders:
"   <TIMESTAMP>   : Replaced by the formatted timestamp (if enabled)
"   <MARKER>      : Replaced by g:chat_role_prefix_marker
"   <ROLENAME>    : Replaced by g:chat_user_role_name or g:chat_gemini_role_name
"   <ROLEPROMPT>  : Replaced by g:chat_role_prompt_suffix
"
" Default: '<TIMESTAMP><MARKER><ROLENAME><ROLEPROMPT>'
" This will result in: '[2024-01-23 14:35:01] #### Tom:'
if !exists('g:chat_prefix_style')
    let g:chat_prefix_style = '<TIMESTAMP><MARKER><ROLENAME><ROLEPROMPT>'
endif

if !exists('g:gemini_replacements')
let g:gemini_replacements = {
    \ 'TODO': 'Action Item',
    \ 'FIXME': 'Correction Needed',
    \ 'deprecated': 'legacy_code',
    \ 'user': 'customer',
    \ 'password': 'access_token',
    \ 'sensitive_data': 'confidential_information',
    \ }
endif

" Configuration Variables (place these in your init.vim/init.lua)
" g:gemini_default_model: already assumed to exist
if !exists('g:gemini_send_visual_selection_prompt_template')
    " This template will wrap your selected text.
    " Use {text} as a placeholder for the visual selection.
    " Example: "Explain this code:\n{text}"
    " Example: "Summarize the following:\n{text}"
    " Example: "Refactor this Vimscript:\n{text}"
    let g:gemini_send_visual_selection_prompt_template = "{text}"
endif

if !exists('g:gemini_send_visual_selection_display_mode')
    " How to display the Gemini response:
    " 'new_buffer': Open in a new scratch buffer (default, best for code/long text)
    " 'popup': Display in a floating window (good for short summaries)
    " 'insert': Insert at current cursor position (be careful, no undo specific to this)
    " 'echomsg': Display as a message in the command line (truncated for long text)
    let g:gemini_send_visual_selection_display_mode = 'popup'
endif

" Default configuration for GeminiAsk logging
if !exists('g:gemini_ask_log_enabled')
    let g:gemini_ask_log_enabled = 1 " Set to 0 to disable file logging
endif
if !exists('g:gemini_ask_log_dir')
    " Default to a subdirectory in Vim's configuration directory (XDG Base Dir spec compliant)
    " Or you can use expand('~/.gemini-vim-logs') for a simpler home directory approach
    let g:gemini_ask_log_dir = empty($XDG_STATE_HOME) ? expand('~/.local/state/vim-gemini-ask') : $XDG_STATE_HOME . '/vim-gemini-ask'
endif
if !exists('g:gemini_ask_log_base_filename')
    let g:gemini_ask_log_base_filename = 'chat.log'
endif
if !exists('g:gemini_ask_log_max_lines')
    let g:gemini_ask_log_max_lines = 0 " Max lines per log file before rotation
endif
if !exists('g:gemini_ask_log_max_files')
    let g:gemini_ask_log_max_files = 5 " Number of rotated files to keep (e.g., chat.log, chat.log.1, ..., chat.log.4)
endif
if !exists('g:gemini_ask_auto_save_chat_enabled')
    let g:gemini_ask_auto_save_chat_enabled = 0 " Set to 1 to enable auto-saving of chat sessions
endif
if !exists('g:gemini_ask_auto_save_chat_interval_ms')
    " Interval in milliseconds for auto-saving. ms = 5 minutes.
    let g:gemini_ask_auto_save_chat_interval_ms = 60000
endif
if !exists('g:gemini_ask_auto_save_chat_timer_id')
    " Internal variable to store the timer ID, don't set this manually
    let g:gemini_ask_auto_save_chat_timer_id = 0
endif

augroup gemini_ask_timers
    autocmd!
    " Start the timer when Vim starts, if auto-save is enabled
    autocmd VimEnter * if g:gemini_ask_auto_save_chat_enabled | call gemini#StartChatAutoSaveTimer() | endif
    " Stop the timer when Vim exits to clean up
    autocmd VimLeavePre * call gemini#StopChatAutoSaveTimer()
augroup END

" Autocommand group to manage Gemini cleanup tasks
" Clear any existing autocommands in this group to prevent duplicates if sourced multiple times
augroup GeminiChatCleanup
	autocmd!
	" When Vim is about to leave, call the function to end all sessions
	autocmd VimLeavePre * call gemini#EndAllChatSessions()
augroup END

" Autocommand group for Gemini auto-save on exit
augroup GeminiAutoSaveOnExit
    " Clear existing autocommands in this group to prevent duplicates
    autocmd!
    " When Vim is about to exit (VimLeavePre),
    " call the auto-save function for all chat sessions.
    " The function itself contains the check for g:gemini_ask_auto_save_chat_enabled.
    autocmd VimLeavePre * call gemini#AutoSaveAllChatSessions()
augroup END

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

" Command to save the current GeminiAsk chat buffer.
command! GeminiAskSaveLog call gemini#SaveAskLog()

" Command: :GeminiAskVisual
" Visually select code, then ask Gemini a question about it.
" RESTORED '-range=%' for standard visual mode usage.
"command! -range=% GeminiAskVisual call gemini#AskVisual()
command! -range -nargs=* GeminiAskVisual call gemini#AskVisual(<f-args>)

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
command! -range=% -nargs=* GeminiReplaceVisual call gemini#SendVisualSelectionReplace(<f-args>)

" --- Chat Session Commands ---

" Command: :GeminiChatStart
" Starts a new Gemini chat session and opens a dedicated chat buffer.
command! -nargs=0 GeminiChatStart call gemini#StartChat()

" Command to save the current GeminiAsk chat buffer.
command! -nargs=? GeminiAskSaveChat call gemini#SaveChatLog(<f-args>)

" Command: :GeminiChatSend {message}
" Sends a message to the currently active Gemini chat session.
" The message and response are appended to the chat buffer.
command! -nargs=1 GeminiChatSend call gemini#SendMessage(<f-args>)

" Command: :GeminiChatSendVisual
" Sends the visually selected text as a message to the current chat session.
command! -range=% -nargs=* GeminiChatSendVisual call gemini#SendVisualSelectionToChat(<f-args>)

" Command: :GeminiChatSendBuffer
" Sends the entire current buffer content as a message to the current chat session.
command! -nargs=0 GeminiChatSendBuffer call gemini#SendBufferToChat()

command! -nargs=* GeminiChatSendFiles call gemini#SendFilesOrPrompt(<f-args>)

" Command to select files using FZF and send them
command! GeminiChatSelectFiles call gemini#SendFzfFilesToChat()

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
