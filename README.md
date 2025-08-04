```markdown
==============================================================================
1. INTRODUCTION                                               *gemini-intro*

This plugin provides integration with the Google Gemini AI API directly within
Vim. You can send code snippets, selections, or entire buffers to Gemini
for various tasks like code generation, summarization, or refactoring.
It also supports multi-turn conversational chat sessions.

==============================================================================
2. REQUIREMENTS AND INSTALLATION                              *gemini-install*

1.  **Vim/Neovim Requirements**:
    * Vim (or Neovim) compiled with Python 3 support.
        Check with `:echo has('python3')` (should return `1`).

2.  **Python Requirements**:
    * Python 3 installed on your system.
    * The Google AI Python SDK: `pip install google-generativeai`.

3.  **API Key Setup**:                                     *gemini-api-key*
    The plugin requires your Google Gemini API key. By default, it looks for
    it in the file `~/.config/gemini.token`.
    Alternatively, you can configure it to read from an environment variable.

    **Option A: API Key in File (Recommended for security)**
    1.  Obtain your API key from [Google AI Studio](https://aistudio.google.com/).
    2.  Create a file: `~/.config/gemini.token`
    3.  Paste *only* your API key into this file.
    4.  Set restrictive file permissions: `chmod 600 ~/.config/gemini.token`
        (This ensures only you can read the file).

    **Option B: API Key in Environment Variable**
    1.  Obtain your API key from [Google AI Studio](https://aistudio.google.com/).
    2.  Add this to your shell's profile (e.g., `~/.bashrc`, `~/.zshrc`, `~/.profile`):
        ```bash
        export GEMINI_API_KEY="YOUR_ACTUAL_GEMINI_API_KEY_HERE"
        ```
    3.  After adding, run `source ~/.bashrc` (or your relevant shell config file)
        and launch Vim from that terminal.
    4.  You then need to configure the plugin in your `.vimrc` to use this
        environment variable instead of the default file path (see *gemini-config*).

    You can verify if Vim can see the API key by attempting to use any plugin
    command. Error messages will indicate if the key is not found.

4.  **Plugin Manager (Recommended)**:
    If you use `vim-plug`, add the following to your `init.vim` or `.vimrc`:
    ```vim
    Plug 'Chunyu-Hu/vim-ai-gemini' " Change to your actual repo URL
    ```
    Then run `:PlugInstall`.

5.  **Manual Installation**:
    Clone this repository or download the files, then copy the `plugin/`,
    `autoload/`, `pythonx/`, and `doc/` directories into your Vim
    runtimepath (e.g., `~/.vim/` for Vim or `~/.config/nvim/` for Neovim).

==============================================================================
3. USAGE                                                      *gemini-usage*

The plugin provides several commands, categorized by their function.

--- Single-Turn Generation Commands ---

These commands send a prompt to Gemini and display the response in a *new
scratch buffer*. They do not maintain conversational context.

* `:GeminiAsk [prompt]`                                  *GeminiAsk*
    If `prompt` is provided, sends that string directly to Gemini.
    If no `prompt` is given, a prompt will appear at the command line for
    your input.
    *Example*: `:GeminiAsk "Explain quantum entanglement in simple terms."`
    *Example*: `:GeminiAsk` (then type your question)

* `:GeminiAskVisual [prompt]`                               *GeminiGenerateVisual*
    In visual mode, select a block of text (e.g., a function).
    Execute this command. The selected text will be sent to the Gemini API,
    and the response will be displayed in a new scratch buffer.
    *Example*: Select a function, then `:'<,'>GeminiAskVisual`

* `:GeminiGenerateVisual`                               *GeminiGenerateVisual*
    In visual mode, select a block of text (e.g., a function).
    Execute this command. The selected text will be sent to the Gemini API,
    and the response will be displayed in a new scratch buffer.
    *Example*: Select a function, then `:'<,'>GeminiGenerateVisual`

* `:GeminiGenerateBuffer`                               *GeminiGenerateBuffer*
    Sends the entire content of the current buffer to the Gemini API.
    The response will be displayed in a new scratch buffer.
    *Example*: `:GeminiGenerateBuffer`

* `:GeminiReplaceVisual`                                *GeminiReplaceVisual*
    In visual mode, select a block of text. Execute this command.
    The selected text will be sent to the Gemini API, and the response will
    **replace the original selection** directly in your buffer. Use with care!
    *Example*: Select a function, then `:'<,'>GeminiReplaceVisual`

--- Chat Session Commands ---

These commands allow for multi-turn conversations with Gemini, where the AI
remembers previous turns in the session.

* `:GeminiChatStart`                                    *GeminiChatStart*
    Starts a new Gemini chat session and opens a dedicated scratch buffer for
    the chat history. This buffer will be set as the current buffer.
    The session ID will be displayed.

* `:GeminiChatSend {message}`                           *GeminiChatSend*
    Sends the provided `message` to the currently active Gemini chat session.
    The message and Gemini's reply will be appended to the chat buffer.
    *Example*: `:GeminiChatSend "What is the capital of France?"`

* `:GeminiChatSendVisual [prompt]`                      *GeminiChatSendVisual*
    In visual mode, select text. This text will be sent as a message to the
    current chat session. Useful for providing code snippets as context.
    *Example*: Select code, then `:'<,'>GeminiChatSendVisual`

* `:GeminiChatSendBuffer [prompt]`                      *GeminiChatSendBuffer*
    Sends the entire content of the current buffer as a message to the
    current chat session.
    *Example*: `:GeminiChatSendBuffer`

* `:GeminiChatSendFiles [file1 file2 ...]`              *GeminiChatSendFiles*
    Sends the entire content of the provide files as a message to the
    current chat session.
    *Example*: `:GeminiChatSendFiles`

* `:GeminiChatSelectFiles`                       *GeminiChatSelectFiles*
    Sends the files as a message to the current chat session, requires
    vim-fzf. Select the files with 'Tab' key. And 'Enter' will send all
    files to the current Chat session.
    *Example*: `:GeminiChatSelectFiles`

* `:GeminiChatList`                                     *GeminiChatList*
    Lists all currently active Gemini chat sessions by their ID prefixes and
    associated buffer names.

* `:GeminiChatSwitch {session_id_prefix}`               *GeminiChatSwitch*
    Switches your active chat session to the one identified by `session_id_prefix`
    (usually the first 8 characters of the full session ID, as shown by
    `:GeminiChatList`). The corresponding chat buffer will be opened.
    *Example*: `:GeminiChatSwitch 1a2b3c4d`

* `:GeminiChatEnd {session_id_prefix}`                  *GeminiChatEnd*
    Ends and closes the chat session identified by `session_id_prefix`.
    The associated chat buffer will be deleted.
    *Example*: `:GeminiChatEnd 1a2b3c4d`

--- Recommended Mappings (add to your `.vimrc`) ---
The plugin does not provide default mappings to avoid conflicts. You can add
your own to your `~/.vimrc` or `~/.config/nvim/init.vim`.

```vim
" General Gemini Commands
nnoremap <Leader>ga :GeminiAsk <C-r>=expand("<cword>")<CR><CR> " Ask about word under cursor
nnoremap <Leader>gA :GeminiAsk<CR>                           " Ask a new question via prompt
nnoremap <Leader>gb :GeminiGenerateBuffer<CR>               " Send buffer to Gemini

" Visual Mode Replacements/Generations
vnoremap <Leader>gg :<C-u>GeminiGenerateVisual<CR>           " Generate (new buffer)
vnoremap <Leader>gr :<C-u>GeminiReplaceVisual<CR>            " Replace in-place

" Chat Commands
nnoremap <Leader>cs :GeminiChatStart<CR>                     " Start new chat
nnoremap <Leader>cc :GeminiChatSend<Space>                  " Send message (prompt for input)
vnoremap <Leader>cv :<C-u>GeminiChatSendVisual<CR>           " Send visual selection to chat
nnoremap <Leader>cB :GeminiChatSendBuffer<CR>               " Send buffer to chat
nnoremap <Leader>cl :GeminiChatList<CR>                     " List chats
nnoremap <Leader>ce :GeminiChatEnd<Space>                   " End chat (prompt for ID)

" Configure variables:
" AI plugins setups
let g:gemini_default_model = 'gemini-2.5-pro'
"let g:gemini_api_key_source = 'GEMINI_API_KEY'

let g:gemini_replacements = {
    \ 'dav': 'fruit',
    \ 'Dave': 'cloud',
    \ 'token': 'food'
    \ }

" Enable timestamps for chat messages
let g:chat_timestamp_enabled = 1

" Set custom role names
let g:chat_user_role_name = 'Tom'
let g:chat_gemini_role_name = 'Teacher'
let g:gemini_log_use_starttime = 1
let g:gemini_record_ask_history = 0
let g:vim_markdown_folding_level = 1



