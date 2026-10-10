# ~/.zshrc - Zsh configuration

# =============================================================================
# PROMPT (Starship)
# =============================================================================
eval "$(starship init zsh)"

# =============================================================================
# HISTORY
# =============================================================================
HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_DUPS       # don't record a duplicate of the previous command
setopt HIST_IGNORE_ALL_DUPS   # remove older duplicate entries
setopt HIST_IGNORE_SPACE      # don't record commands starting with a space
setopt HIST_REDUCE_BLANKS     # trim superfluous whitespace
setopt SHARE_HISTORY          # share history across concurrent sessions
setopt APPEND_HISTORY         # append rather than overwrite

# =============================================================================
# SHELL OPTIONS
# =============================================================================
setopt AUTO_CD                # `dir` instead of `cd dir`
setopt AUTO_PUSHD             # push visited dirs onto the stack
setopt PUSHD_IGNORE_DUPS      # no duplicate entries on the dir stack
setopt INTERACTIVE_COMMENTS   # allow # comments in interactive shell

# =============================================================================
# COMPLETION
# =============================================================================
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'  # case-insensitive

# =============================================================================
# ALIASES - general
# =============================================================================
alias ..="cd .."
alias ...="cd ../.."

alias grep="grep --color=auto"
alias diff="diff --color=auto"
alias cls="clear"
alias h="history"
alias q="exit"
alias e="$EDITOR"

alias ls="eza --icons --group-directories-first"
alias ll="eza -la --icons --git --group-directories-first"
alias la="eza -a --icons --group-directories-first"
alias lt="eza --tree --level=2 --icons"

# Tools
alias o="opencode"
alias cat="bat"

# =============================================================================
# ALIASES - navigation
# =============================================================================
alias dev="cd ~/code"

# =============================================================================
# ALIASES - git
# =============================================================================
alias g="git"
alias gs="git status"
alias ga="git add"
alias gaa="git add --all"
alias gc="git commit -m"
alias gp="git push"
alias gpl="git pull"
alias gb="git branch"
alias gco="git checkout"
alias gcb="git checkout -b"
alias gd="git diff"
alias gds="git diff --staged"
alias gl="git log --oneline --graph --decorate"
alias glo="git log --oneline --graph --decorate --all"

# =============================================================================
# ALIASES - ssh
# =============================================================================

# =============================================================================
# FUNCTIONS
# =============================================================================
# Update all Homebrew packages and casks, then clean up
update() {
  brew update && brew upgrade && brew upgrade --cask && brew cleanup
}

# Delete all Azure resource groups (async, no confirmation prompts)
azclean() {
  az group list --query "[].name" -o tsv | xargs -I {} az group delete -n {} --yes --no-wait
}

# =============================================================================
# STARTUP
# =============================================================================
if command -v fastfetch >/dev/null 2>&1; then
  fastfetch --logo none --structure os:uptime:memory:disk:swap:packages:battery:localip
fi
