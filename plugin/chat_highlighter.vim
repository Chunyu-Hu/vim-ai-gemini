" ============================================================================
" Chat Session Highlighting Functions
" ============================================================================

" --- 0. Global Configuration Variables ---
" Define a global dictionary for speaker roles and their colors.
" Users can override these defaults by setting `g:chat_speaker_roles` in their
" .vimrc *before* this plugin is loaded (e.g., in a file sourced earlier).
if !exists('g:chat_speaker_roles')
    let g:chat_speaker_roles = {
        \ 'User':         {'ctermfg': 'cyan',    'cterm': 'bold', 'guifg': '#00FFFF', 'gui': 'bold'},
        \ 'Tom':         {'ctermfg': 'cyan',    'cterm': 'bold', 'guifg': '#00FFFF', 'gui': 'bold'},
        \ 'AI':          {'ctermfg': 'green',   'cterm': 'bold', 'guifg': '#0000FF', 'gui': 'bold'},
        \ 'Gemini':          {'ctermfg': 'green',   'cterm': 'bold', 'guifg': '#0000FF', 'gui': 'bold'},
        \ 'Teacher':       {'ctermfg': 'yellow',  'cterm': 'bold', 'guifg': '#FFFFFF', 'gui': 'bold'},
        \ 'User123_Bot': {'ctermfg': 'magenta', 'cterm': 'bold', 'guifg': '#FFFFFF', 'gui': 'bold'},
        \ 'AnotherUser': {'ctermfg': 'red',     'cterm': 'bold', 'guifg': '#FF0000', 'gui': 'bold'}
        \ }
endif

" --- 1. Helper Function to Define Highlight Group ---
" This function ensures a highlight group is defined only once,
" allowing user's colorscheme or manual highlight commands to override.
function! s:define_highlight_group(name, colors) abort
    if !hlexists(a:name)
        let l:cmd = 'highlight default ' . a:name
        if has_key(a:colors, 'ctermfg') | let l:cmd .= ' ctermfg=' . a:colors.ctermfg | endif
        if has_key(a:colors, 'cterm')   | let l:cmd .= ' cterm=' . a:colors.cterm   | endif
        if has_key(a:colors, 'guifg')   | let l:cmd .= ' guifg=' . a:colors.guifg   | endif
        if has_key(a:colors, 'gui')     | let l:cmd .= ' gui=' . a:colors.gui       | endif
        execute l:cmd
    endif
endfunction

" --- 2. Main Function to Apply Chat Speaker Highlighting ---
" This function accepts a dictionary mapping speaker nicknames to their colors.
" The highlight applies to the '#### [TIMESTAMP] Nickname:' part.
function! ApplyGeminiHighlights(role_colors) abort
    " Clear all existing matchadd() highlights in the current buffer.
    " This is crucial to avoid highlight accumulation if the function is re-run.
    if exists('*clearmatches')
        call clearmatches()
    endif

    " Loop through each role and apply specific highlighting
    for [l:role_name, l:color_def] in items(a:role_colors)
        " Create a unique highlight group name for each role
        let l:hl_group_name = 'ChatSpeaker_' . substitute(l:role_name, '\W', '', 'g')
        " Ensure the highlight group is defined
        call s:define_highlight_group(l:hl_group_name, l:color_def)

        " Construct the regex for the specific role.
        " Escape special regex characters in the role name.
        " Pattern: ^#### [TIMESTAMP] Nickname:
        let l:escaped_role_name = escape(l:role_name, '\^$.*+?|()[]{}/')
        let l:pattern = printf('^\v#### \[[^]]*\]\s*%s:', l:escaped_role_name)

        " Apply the highlight using matchadd
        call matchadd(l:hl_group_name, l:pattern, -1)
    endfor
endfunction

" --- 3. User Command to Trigger Highlighting ---
" This command will apply the highlighting using the global g:chat_speaker_roles.
command! HighlightChatLogSpeaker call ApplyGeminiHighlights(g:chat_speaker_roles)

" --- 4. Optional: Auto-detection and Application ---
" This section automatically applies the highlighting when a recognized chat log
" file is opened. It checks the first line for the Gemini chat session header.
autocmd BufReadPost,BufNewFile * call s:AutoHighlightChatLogSpeaker()

function! s:AutoHighlightChatLogSpeaker() abort
    " Only apply if the buffer is not empty and the first line looks like a chat log
    if line('$') >= 1 && getline(1) =~ '^# Gemini Chat Session'
        " Use the global role colors for auto-highlighting as well
        call ApplyGeminiHighlights(g:chat_speaker_roles)
    endif
endfunction

" ============================================================================
" Additional: Function for the '### User:' / '### Gemini:' format
" (This part is separate as it targets a different log format)
" ============================================================================
" This function handles the '### User:' and '### Gemini:' patterns
" as seen in your provided snippet.
function! s:apply_gemini_format_highlights() abort
    " Clear all existing matchadd() highlights (important!)
    if exists('*clearmatches')
        call clearmatches()
    endif

    " Define custom highlight groups.
    " These colors are currently hardcoded in this function. If you want them
    " to be user-configurable globally, you'd define another `g:gemini_format_roles`
    " dictionary similar to `g:chat_speaker_roles`.
    call s:define_highlight_group('GeminiUserPrompt', {'ctermfg': 'cyan', 'cterm': 'bold', 'guifg': '#00FFFF', 'gui': 'bold'})
    call s:define_highlight_group('GeminiAIResponse', {'ctermfg': 'green', 'cterm': 'bold', 'guifg': '#00F', 'gui': 'bold'})
    call s:define_highlight_group('GeminiHeader',     {'ctermfg': 'yellow', 'cterm': 'bold', 'guifg': '#FFF', 'gui': 'bold'})

    " Apply matches for the specific headers in the current buffer.
    call matchadd('GeminiHeader', '^### \(User\|Gemini\):', -1)
    call matchadd('GeminiUserPrompt', '^### User:.*', -1)
    call matchadd('GeminiAIResponse', '^### Gemini:.*', -1)
endfunction

" Command for the '###' format
command! HighlightGeminiFormat call s:apply_gemini_format_highlights()


" --- 4. Optional: Auto-detection and Application ---
" This section automatically applies the highlighting when a recognized chat log
" file is opened. It checks the first line for the Gemini chat session header.
autocmd BufReadPost,BufNewFile * call s:AutoHighlightChatLogSpeaker()

function! s:AutoHighlightChatLogSpeaker() abort
    " Only apply if the buffer is not empty and the first line looks like a chat log
    if line('$') >= 1 && getline(1) =~ '^# Gemini Chat Session'
        " Use the global role colors for auto-highlighting as well
        call ApplyGeminiHighlights(g:chat_speaker_roles)
    endif
endfunction
