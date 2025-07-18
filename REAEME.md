```markdown
# Vim Gemini AI Plugin

A Vim/Neovim plugin for integrating with the Google Gemini AI API, enabling
text generation, code assistance, and conversational chat sessions directly
within your editor.

## Features

* **Single-Turn Generation**:
    * Ask questions via command prompt (`:GeminiAsk`).
    * Send visual selections or entire buffers for generation/summarization
        (output to new scratch buffer: `:GeminiGenerateVisual`, `:GeminiGenerateBuffer`).
* **In-Place Replacement**:
    * Select text and have Gemini replace it directly in your buffer
        (`:GeminiReplaceVisual`).
* **Conversational Chat Sessions**:
    * Start new chat sessions (`:GeminiChatStart`).
    * Send messages to active sessions (from input, visual selection, or buffer:
        `:GeminiChatSend`, `:GeminiChatSendVisual`, `:GeminiChatSendBuffer`).
    * Dedicated chat buffers to view conversation history.
    * List and switch between active sessions (`:GeminiChatList`).
    * End sessions (`:GeminiChatEnd`).

## Requirements

* Vim (or Neovim) compiled with **Python 3 support**.
    (Check with `:echo has('python3')` in Vim, should output `1`).
* Python 3 installed on your system.
* The Google AI Python SDK:
    ```bash
    pip install google-generativeai
    ```

## Installation

### 1. Set Your Gemini API Key

Obtain your API key from [Google AI Studio](https://aistudio.google.com/).
You can configure the plugin to read the API key from a file (recommended) or an environment variable.

**Option A: API Key in File (Default & Recommended)**
1.  Create a file at `~/.config/gemini.token`.
2.  Paste *only* your API key into this file.
3.  Set restrictive file permissions: `chmod 600 ~/.config/gemini.token`
    (This ensures only you can read the file).

**Option B: API Key in Environment Variable**
1.  Add `export GEMINI_API_KEY="YOUR_ACTUAL_GEMINI_API_KEY_HERE"` to your shell's profile (e.g., `~/.bashrc`, `~/.zshrc`).
2.  Then, configure the plugin in your `.vimrc` to use this environment variable:
    ```vim
    let g:gemini_api_key_source = 'GEMINI_API_KEY'
    ```

### 2. Install the Plugin

**Using `vim-plug` (Recommended):**

Add this line to your `init.vim` or `.vimrc`:

```vim
Plug 'your_github_username/vim-gemini-ai' " Replace with your actual GitHub repo path
