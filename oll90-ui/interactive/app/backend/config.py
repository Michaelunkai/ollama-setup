"""oll90 v3 Backend Configuration — 54 tools"""

OLLAMA_URL = "http://127.0.0.1:11434"
OLLAMA_MODEL = "qwen3-14b-oll90"
PORT = 8090
HOST = "0.0.0.0"

MAX_TOOL_ITERATIONS = 80
TOOL_TIMEOUT_SECONDS = 180
MAX_OUTPUT_CHARS = 30000

CONTEXT_WINDOW = 32768
COMPACTION_THRESHOLD = 0.95

DB_PATH = "data/sessions.db"

ERROR_PATTERN_WINDOW = 5
MAX_REPEATED_ERRORS = 3

# Reflection interval: inject self-reflection prompt every N tool calls
REFLECTION_INTERVAL = 5

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "run_powershell",
            "description": "Execute a PowerShell command on Windows 11 Pro. Returns stdout and stderr. Use for ALL system operations: Get-Process, Get-ChildItem, Get-CimInstance, nvidia-smi, Get-NetAdapter, Get-EventLog, registry queries. Chain commands with semicolons (;), NEVER use &&. Use absolute Windows paths (C:\\, F:\\).",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "The PowerShell command to execute",
                    }
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_cmd",
            "description": "Execute a CMD.exe command. Use for: dir, type, tree, batch files, or programs that behave differently under cmd.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "The CMD command to execute",
                    }
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_python",
            "description": "Execute Python code directly. Use for data processing, calculations, JSON manipulation, or when PowerShell syntax is awkward. Returns stdout and stderr. The code runs as a temp .py file with Python 3.12.",
            "parameters": {
                "type": "object",
                "properties": {
                    "code": {"type": "string", "description": "Python code to execute"}
                },
                "required": ["code"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Write content to an absolute Windows path. Creates parent directories automatically. Overwrites existing files. Use UTF-8 encoding without BOM.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Absolute file path (e.g. C:\\Temp\\script.ps1)",
                    },
                    "content": {
                        "type": "string",
                        "description": "Content to write to the file",
                    },
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read file content by absolute path. Returns the full content as a string.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Absolute file path to read",
                    }
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "edit_file",
            "description": "Edit a file by replacing a specific text block with new text. The old_text must match exactly one location in the file. Use read_file first to see current content.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute file path"},
                    "old_text": {
                        "type": "string",
                        "description": "Exact text to find and replace (must be unique in the file)",
                    },
                    "new_text": {"type": "string", "description": "Replacement text"},
                },
                "required": ["path", "old_text", "new_text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_directory",
            "description": "Create a directory and all parent directories. Returns success message with the created path.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Absolute directory path to create",
                    }
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "move_file",
            "description": "Move or rename a file or directory. Creates destination parent directories automatically.",
            "parameters": {
                "type": "object",
                "properties": {
                    "source": {"type": "string", "description": "Source absolute path"},
                    "destination": {
                        "type": "string",
                        "description": "Destination absolute path",
                    },
                },
                "required": ["source", "destination"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "delete_file",
            "description": "Delete a file or empty directory. Has safety guards — refuses to delete critical system paths (C:\\Windows, C:\\Users, registry-related). For non-empty directories, use run_powershell with Remove-Item -Recurse.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute path to delete"}
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_directory",
            "description": "List files and directories at the specified path with sizes, dates, and types.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Absolute directory path",
                    },
                    "recursive": {
                        "type": "boolean",
                        "description": "If true, list recursively. Default false.",
                    },
                    "pattern": {
                        "type": "string",
                        "description": "Glob pattern filter, e.g. *.txt. Default *",
                    },
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_files",
            "description": "Search file contents for a text pattern (regex). Returns matching lines with file paths and line numbers. Max 50 results.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Directory to search in"},
                    "pattern": {
                        "type": "string",
                        "description": "Regex pattern to search for",
                    },
                    "file_glob": {
                        "type": "string",
                        "description": "Only search files matching this glob. Default *.*",
                    },
                },
                "required": ["path", "pattern"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_system_info",
            "description": "Snapshot of CPU, RAM, GPU (via nvidia-smi), disks, and OS info. No parameters needed. Use for quick system overview.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Search the internet using DuckDuckGo. Returns titles, snippets, and URLs for up to 8 results. Use FIRST when you need current information, news, documentation, or anything from the web.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "The search query"},
                    "max_results": {
                        "type": "integer",
                        "description": "Number of results to return (1-8, default 8)",
                    },
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_fetch",
            "description": "HTTP GET a URL and return text content with HTML tags stripped. Max 25K chars. Use after web_search to read full page content.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "The URL to fetch (must start with http:// or https://)",
                    }
                },
                "required": ["url"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "http_request",
            "description": "Full HTTP client for REST APIs. Supports GET, POST, PUT, DELETE, PATCH with custom headers and request body. Returns status code, headers, and response body. Use for API interactions beyond simple GET.",
            "parameters": {
                "type": "object",
                "properties": {
                    "method": {
                        "type": "string",
                        "description": "HTTP method: GET, POST, PUT, DELETE, PATCH",
                    },
                    "url": {
                        "type": "string",
                        "description": "The URL (must start with http:// or https://)",
                    },
                    "headers": {
                        "type": "object",
                        "description": "Optional HTTP headers as key-value pairs",
                    },
                    "body": {
                        "type": "string",
                        "description": "Optional request body (JSON string, form data, etc.)",
                    },
                },
                "required": ["method", "url"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "download_file",
            "description": "Download a file from a URL and save it to an absolute Windows path. Use for GitHub raw files, installers, scripts, ZIP files.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "URL to download (must start with http:// or https://)",
                    },
                    "path": {
                        "type": "string",
                        "description": "Absolute local path to save the file (e.g. C:\\Temp\\script.ps1)",
                    },
                },
                "required": ["url", "path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_current_datetime",
            "description": "Get the current date, time, day-of-week, and UTC offset. Use this FIRST whenever the user asks about current date/time, or when you need to know what day/time it is right now. No parameters needed.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_news",
            "description": "Search for recent news articles via DuckDuckGo News. Returns titles, dates, snippets, and URLs. Use for questions about current events, recent releases, today's news, or anything that happened recently.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "News search query"},
                    "max_results": {
                        "type": "integer",
                        "description": "Number of results (1-8, default 8)",
                    },
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_fetch_json",
            "description": "Fetch a URL and parse as JSON. Returns pretty-printed JSON. Use for REST APIs, GitHub API, weather APIs, status APIs, or any URL returning JSON data.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "URL to fetch as JSON (must start with http:// or https://)",
                    }
                },
                "required": ["url"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "dns_lookup",
            "description": "Resolve a hostname to IP addresses via DNS. Use for network diagnostics, verifying domains, checking if a site is reachable.",
            "parameters": {
                "type": "object",
                "properties": {
                    "hostname": {
                        "type": "string",
                        "description": "Hostname or URL to resolve (e.g. google.com or https://google.com)",
                    }
                },
                "required": ["hostname"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "port_check",
            "description": "Check if a TCP port is open on a host. Returns open/closed status and latency. Use for network diagnostics, checking if a service is running.",
            "parameters": {
                "type": "object",
                "properties": {
                    "host": {
                        "type": "string",
                        "description": "Hostname or IP to check",
                    },
                    "port": {"type": "integer", "description": "TCP port number"},
                    "timeout_sec": {
                        "type": "number",
                        "description": "Connection timeout in seconds (default 3.0)",
                    },
                },
                "required": ["host", "port"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "network_ping",
            "description": "Ping a host using ICMP. Returns RTT min/avg/max and packet loss. Use for network connectivity tests.",
            "parameters": {
                "type": "object",
                "properties": {
                    "host": {"type": "string", "description": "Hostname or IP to ping"},
                    "count": {
                        "type": "integer",
                        "description": "Number of ping packets (1-10, default 4)",
                    },
                },
                "required": ["host"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "rss_fetch",
            "description": "Fetch and parse an RSS or Atom feed. Returns titles, dates, links, and summaries. Use for news feeds, blog updates, release notes, or any RSS/Atom URL.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "RSS or Atom feed URL"},
                    "max_items": {
                        "type": "integer",
                        "description": "Max items to return (default 10)",
                    },
                },
                "required": ["url"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "open_browser",
            "description": "Open a URL in Google Chrome. Opens new tab by default. Use to launch websites, YouTube, playlists, or any web page in the user's browser.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "URL to open (e.g. youtube.com, https://youtube.com/playlist?list=...)",
                    },
                    "new_tab": {
                        "type": "boolean",
                        "description": "If true, open new tab (default). If false, open new window.",
                    },
                },
                "required": ["url"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "clipboard_read",
            "description": "Read text from the Windows clipboard. No parameters needed.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "clipboard_write",
            "description": "Write text to the Windows clipboard.",
            "parameters": {
                "type": "object",
                "properties": {"text": {"type": "string", "description": "Text to write to clipboard"}},
                "required": ["text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "network_info",
            "description": "Get network information. Actions: interfaces (adapters), connections (active TCP), dns (DNS servers).",
            "parameters": {
                "type": "object",
                "properties": {"action": {"type": "string", "description": "interfaces, connections, or dns (default: interfaces)"}},
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "hash_file",
            "description": "Compute file hash. Supports MD5, SHA1, SHA256, SHA512.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute file path"},
                    "algorithm": {"type": "string", "description": "MD5, SHA1, SHA256, SHA512 (default SHA256)"},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "event_log",
            "description": "Read Windows Event Log entries (System, Application, Security).",
            "parameters": {
                "type": "object",
                "properties": {
                    "log_name": {"type": "string", "description": "Log name: System, Application, Security (default System)"},
                    "count": {"type": "integer", "description": "Number of entries (1-100, default 20)"},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "git_command",
            "description": "Run a git command in a specified repository directory.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Git command (e.g. 'log --oneline -10')"},
                    "repo_path": {"type": "string", "description": "Repository directory path (default '.')"},
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "process_manager",
            "description": "List, kill, or start processes. Actions: list (top 30 by RAM), kill (by name or PID), start (by path).",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "description": "list, kill, or start (default list)"},
                    "name": {"type": "string", "description": "Process name or path"},
                    "pid": {"type": "integer", "description": "Process ID (for kill)"},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "service_control",
            "description": "List, start, stop, or restart Windows services.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "description": "list, start, stop, restart (default list)"},
                    "name": {"type": "string", "description": "Service name (for start/stop/restart)"},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "compress_files",
            "description": "Create a ZIP archive from a file or directory.",
            "parameters": {
                "type": "object",
                "properties": {
                    "source": {"type": "string", "description": "Source path (file or directory)"},
                    "destination": {"type": "string", "description": "Destination .zip path"},
                },
                "required": ["source", "destination"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "extract_archive",
            "description": "Extract a ZIP archive to a directory.",
            "parameters": {
                "type": "object",
                "properties": {
                    "source": {"type": "string", "description": "ZIP file path"},
                    "destination": {"type": "string", "description": "Extraction directory"},
                },
                "required": ["source", "destination"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "json_transform",
            "description": "Query/transform JSON data with a Python expression. The variable 'data' holds the parsed JSON.",
            "parameters": {
                "type": "object",
                "properties": {
                    "json_text": {"type": "string", "description": "JSON string to parse"},
                    "expression": {"type": "string", "description": "Python expression (e.g. 'data[\"key\"]', 'len(data)')"},
                },
                "required": ["json_text", "expression"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "speak",
            "description": "Text-to-speech using Windows System.Speech. Speaks the text aloud.",
            "parameters": {
                "type": "object",
                "properties": {"text": {"type": "string", "description": "Text to speak"}},
                "required": ["text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "notify",
            "description": "Show a Windows balloon toast notification.",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "Notification title"},
                    "message": {"type": "string", "description": "Notification message body"},
                },
                "required": ["title", "message"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "screenshot",
            "description": "Capture a desktop screenshot to PNG file.",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string", "description": "Save path (optional, auto-generated if empty)"}},
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "scheduled_task",
            "description": "List, run, or delete Windows scheduled tasks.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "description": "list, run, delete (default list)"},
                    "name": {"type": "string", "description": "Task name (for run/delete)"},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "traceroute",
            "description": "Trace network route to a host. Shows each hop along the path.",
            "parameters": {
                "type": "object",
                "properties": {
                    "host": {"type": "string", "description": "Hostname or IP to trace"},
                    "max_hops": {"type": "integer", "description": "Maximum hops (1-30, default 15)"},
                },
                "required": ["host"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "whois_lookup",
            "description": "WHOIS lookup for a domain. Returns registration info.",
            "parameters": {
                "type": "object",
                "properties": {"domain": {"type": "string", "description": "Domain to look up (e.g. google.com)"}},
                "required": ["domain"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "ssl_cert_info",
            "description": "Get SSL/TLS certificate details for a domain (issuer, expiry, SANs).",
            "parameters": {
                "type": "object",
                "properties": {"hostname": {"type": "string", "description": "Domain name (e.g. google.com)"}},
                "required": ["hostname"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "ip_geolocation",
            "description": "Get geolocation info for an IP address, or your own public IP if empty.",
            "parameters": {
                "type": "object",
                "properties": {"ip": {"type": "string", "description": "IP address (leave empty for your own)"}},
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "speed_test",
            "description": "Quick internet download speed test (~10MB). Returns Mbps.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "wifi_info",
            "description": "Get WiFi profile, signal strength, and connection details.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "url_shorten",
            "description": "Shorten a URL using is.gd service.",
            "parameters": {
                "type": "object",
                "properties": {"url": {"type": "string", "description": "URL to shorten"}},
                "required": ["url"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "base64_tool",
            "description": "Encode or decode base64 strings.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "description": "encode or decode (default encode)"},
                    "text": {"type": "string", "description": "Text to encode/decode"},
                },
                "required": ["text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "regex_test",
            "description": "Test a regex pattern against text. Returns all matches with positions and groups.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "Regex pattern"},
                    "text": {"type": "string", "description": "Text to test against"},
                    "flags": {"type": "string", "description": "Flags: i=ignorecase, m=multiline, s=dotall"},
                },
                "required": ["pattern", "text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "env_var",
            "description": "Get, set, or list environment variables.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "description": "list, get, set (default list)"},
                    "name": {"type": "string", "description": "Variable name (for get/set)"},
                    "value": {"type": "string", "description": "Value to set (for set action)"},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "registry_query",
            "description": "Read Windows registry keys and values.",
            "parameters": {
                "type": "object",
                "properties": {
                    "key_path": {"type": "string", "description": "Registry key path (e.g. HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft)"},
                    "value_name": {"type": "string", "description": "Specific value name (optional, lists all if empty)"},
                },
                "required": ["key_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "disk_usage",
            "description": "Get disk usage breakdown for a directory (sizes of top-level subdirectories).",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string", "description": "Directory path to analyze"}},
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "firewall_status",
            "description": "Check Windows Firewall status for all profiles (Domain, Private, Public).",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_screenshot",
            "description": "Take a screenshot of a webpage using headless Chrome. Returns saved PNG path.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "URL to screenshot"},
                    "path": {"type": "string", "description": "Save path (optional, auto-generated if empty)"},
                },
                "required": ["url"],
            },
        },
    },
]
