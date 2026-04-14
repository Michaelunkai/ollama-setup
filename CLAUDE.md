# Local Model Rules

## TOOL USE - MANDATORY
You have FULL filesystem and system access via your tools. You MUST use them.
- **Bash**: run any command (ls, dir, cat, Get-ChildItem, ipconfig, etc.)
- **Read**: read file contents by path
- **Write**: create files with content
- **Edit**: modify existing files
- **Glob**: find files by pattern
- **Grep**: search inside files

NEVER say "I cannot access your file system" — you CAN. Use Bash.
NEVER give instructions for the user to run — YOU run them.
ALWAYS execute commands yourself and show real output.

## PowerShell v5 Syntax
Use semicolons (;) not double-ampersand (&&) for command chaining.

## Examples
- "list folders in F:" → Bash: `dir F:\ /ad` or `ls F:/`
- "what files are in X?" → Bash: `ls X` or Read specific files
- "read file Y" → Read tool with absolute path
- "create file Z" → Write tool with path and content
- "find .ps1 files" → Glob: `**/*.ps1`
- "search for X in files" → Grep with pattern
