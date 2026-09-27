# Shared env for File2File App scripts and interactive shells.
# Compatible with both bash and zsh (do not use `mise activate zsh` here).

export JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

# mise Ruby + CocoaPods (avoid broken system Ruby 2.6 gem path)
_MISE_RUBY_BIN="$HOME/.local/share/mise/installs/ruby/3.3.6/bin"
if [[ -x "$_MISE_RUBY_BIN/ruby" ]]; then
  export PATH="$_MISE_RUBY_BIN:$HOME/.local/bin:$PATH"
fi
unset _MISE_RUBY_BIN

# Drop legacy Ruby 2.6 gem bins if present
_CLEAN_PATH=""
_OLD_IFS=$IFS
IFS=':'
for _p in $PATH; do
  case "$_p" in
    *'/.gem/ruby/2.6'*) ;;
    *)
      if [[ -n "$_CLEAN_PATH" ]]; then
        _CLEAN_PATH="$_CLEAN_PATH:$_p"
      else
        _CLEAN_PATH="$_p"
      fi
      ;;
  esac
done
IFS=$_OLD_IFS
export PATH="$_CLEAN_PATH"
unset _CLEAN_PATH _OLD_IFS _p

export PATH="/Users/a1/development/flutter/bin:$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
