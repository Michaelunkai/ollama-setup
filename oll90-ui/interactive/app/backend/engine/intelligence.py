"""Intelligence engine v3 - enhanced reasoning, self-reflection, and multi-strategy recovery"""
import re
from typing import Optional

from config import REFLECTION_INTERVAL


class AgentIntelligence:
    """Per-turn intelligence for STDERR analysis, loop detection, self-reflection, and interceptors."""

    def __init__(self, user_message: str):
        self.user_message = user_message
        self.recent_errors: list[str] = []
        self.error_pattern_window = 5
        self.max_repeated_errors = 3
        self.thinking_reprompted = False
        self.shallow_scan_reprompted = False
        self.turn_tool_calls = 0
        self.recent_tool_sigs: list[str] = []
        self.tool_results_log: list[dict] = []  # Track all tool outcomes for reflection
        self.reflection_count = 0
        self.strategy_attempts: dict[str, int] = {}  # Track strategy attempts per error type

    def should_reflect(self) -> bool:
        """Check if it's time for a self-reflection injection."""
        if self.turn_tool_calls > 0 and self.turn_tool_calls % REFLECTION_INTERVAL == 0:
            return True
        return False

    def get_reflection_prompt(self) -> str:
        """Generate a self-reflection prompt based on recent tool results."""
        self.reflection_count += 1

        # Analyze recent results
        recent = self.tool_results_log[-REFLECTION_INTERVAL:] if self.tool_results_log else []
        successes = sum(1 for r in recent if r.get("success", False))
        failures = len(recent) - successes
        tools_used = [r.get("tool", "?") for r in recent]

        if failures > successes:
            return (
                f"[REFLECTION #{self.reflection_count}] "
                f"Last {len(recent)} tool calls: {successes} succeeded, {failures} failed. "
                f"Tools used: {', '.join(tools_used)}. "
                f"High failure rate detected. PAUSE and THINK:\n"
                f"1. What is going wrong? Identify the root cause.\n"
                f"2. Are you using the right tools for this task?\n"
                f"3. Should you try a completely different approach?\n"
                f"4. What is the simplest next step that would make progress?\n"
                f"Adjust your plan before continuing."
            )
        elif self.turn_tool_calls >= 20:
            return (
                f"[REFLECTION #{self.reflection_count}] "
                f"{self.turn_tool_calls} tool calls made so far. "
                f"Tools used: {', '.join(tools_used[-5:])}. "
                f"CHECKPOINT: Are you making steady progress toward the goal? "
                f"If you've been going in circles, STOP and summarize what you've accomplished so far. "
                f"If you're on track, state your remaining steps concisely."
            )
        else:
            return (
                f"[REFLECTION #{self.reflection_count}] "
                f"Progress check: {self.turn_tool_calls} tool calls, {successes}/{len(recent)} recent succeeded. "
                f"Are you on the most efficient path? Any shortcuts available?"
            )

    def log_tool_result(self, tool_name: str, success: bool, has_stderr: bool):
        """Log a tool result for reflection analysis."""
        self.tool_results_log.append({
            "tool": tool_name,
            "success": success,
            "has_stderr": has_stderr,
        })

    def analyze_stderr(self, stderr: str) -> Optional[str]:
        """Parse STDERR for known error patterns and return an [AGENT HINT]."""
        if not stderr or not stderr.strip():
            return None

        # Parse error location
        loc_match = re.search(r'At\s+(?:(.+?):)?(\d+)\s+char:(\d+)', stderr)
        if loc_match:
            line_num = loc_match.group(2)
            char_num = loc_match.group(3)
            lower = stderr.lower()

            if any(kw in lower for kw in ['$', 'variable', 'expression', 'variable reference']):
                return (
                    f"[AGENT HINT] Parse error at line:{line_num} char:{char_num} - "
                    "Unescaped $ in double-quoted string. STRATEGY: Use single quotes for literals "
                    "or $() subexpression syntax. Example: 'Error: ' + $varName"
                )

            if any(kw in lower for kw in ['missing', 'unexpected', 'token', 'recognized']):
                return (
                    f"[AGENT HINT] Syntax error at line:{line_num} char:{char_num} - "
                    "Check for missing closing braces, quotes, or parentheses. "
                    "STRATEGY: Simplify the command. Break into smaller steps."
                )

        # Duplicate property
        dup_match = re.search(r"property\s+'(\w+)'\s+cannot be processed.*already exists", stderr, re.IGNORECASE)
        if dup_match:
            return f"[AGENT HINT] Duplicate property '{dup_match.group(1)}' in Select-Object. Remove one instance."

        # Access denied
        if 'access' in stderr.lower() and 'denied' in stderr.lower():
            return "[AGENT HINT] Access denied. STRATEGY: Add -ErrorAction SilentlyContinue for bulk ops, or run as admin."

        # Command not found
        if 'not recognized' in stderr.lower() or 'commandnotfoundexception' in stderr.lower():
            cmd_match = re.search(r"'([^']+)'\s+is not recognized", stderr)
            cmd = cmd_match.group(1) if cmd_match else "the command"
            return f"[AGENT HINT] '{cmd}' not found. STRATEGY: Use full cmdlet names (Get-ChildItem not ls). Check if tool is installed."

        # Timeout
        if 'timed out' in stderr.lower() or 'timeout' in stderr.lower():
            return "[AGENT HINT] Command timed out. STRATEGY: Break into smaller chunks, add -ErrorAction SilentlyContinue, or increase timeout."

        # Path not found
        if 'cannot find path' in stderr.lower() or 'does not exist' in stderr.lower():
            path_match = re.search(r"'([^']+)'", stderr)
            path_str = path_match.group(1) if path_match else "the path"
            return f"[AGENT HINT] Path '{path_str}' not found. STRATEGY: Use Test-Path first. Check for typos. Use list_directory to explore."

        # Module not found
        if 'module' in stderr.lower() and ('not found' in stderr.lower() or 'cannot be loaded' in stderr.lower()):
            return "[AGENT HINT] Module not available. STRATEGY: Get-Module -ListAvailable to check. Try alternative approach without the module."

        # Type conversion
        if 'cannot convert' in stderr.lower() or 'invalid cast' in stderr.lower():
            return "[AGENT HINT] Type conversion error. STRATEGY: Cast explicitly: [int]$var, [string]$var, or use -as operator."

        # Network errors
        if 'connection' in stderr.lower() and ('refused' in stderr.lower() or 'reset' in stderr.lower()):
            return "[AGENT HINT] Network connection failed. STRATEGY: Check if service is running. Try different URL or port. Verify firewall."

        # Encoding errors
        if 'encoding' in stderr.lower() or 'decode' in stderr.lower():
            return "[AGENT HINT] Encoding error. STRATEGY: Use -Encoding UTF8 explicitly or [System.IO.File]::ReadAllText."

        # Permission errors
        if 'permission' in stderr.lower() or 'unauthorized' in stderr.lower():
            return "[AGENT HINT] Permission denied. STRATEGY: Check file/folder permissions. Try running with elevated privileges."

        # Python-specific errors
        if 'traceback' in stderr.lower() or 'importerror' in stderr.lower() or 'modulenotfounderror' in stderr.lower():
            return "[AGENT HINT] Python error detected. STRATEGY: Check imports, install missing packages with pip, verify Python version."

        return None

    def check_loop_detection(self, error_text: str) -> Optional[str]:
        """Track error signatures. Return forced approach-change message after 3 identical errors."""
        sig = re.sub(r'\s+', ' ', error_text[:100]).strip().lower()
        self.recent_errors.append(sig)

        if len(self.recent_errors) > self.error_pattern_window:
            self.recent_errors = self.recent_errors[-self.error_pattern_window:]

        # Check for repeated identical errors
        if len(self.recent_errors) >= self.max_repeated_errors:
            last_n = self.recent_errors[-self.max_repeated_errors:]
            if len(set(last_n)) == 1:
                self.recent_errors.clear()
                # Track which strategy level we're at
                error_type = sig[:50]
                attempt = self.strategy_attempts.get(error_type, 0) + 1
                self.strategy_attempts[error_type] = attempt

                if attempt == 1:
                    return (
                        "[SYSTEM] STUCK DETECTED (Level 1) - Same error repeated 3 times. "
                        "STRATEGY SWITCH REQUIRED:\n"
                        "A) Use single-quoted strings instead of double-quoted\n"
                        "B) Use string concatenation instead of interpolation\n"
                        "C) Simplify the command - break into smaller steps\n"
                        "Pick ONE strategy and commit to it."
                    )
                elif attempt == 2:
                    return (
                        "[SYSTEM] STUCK DETECTED (Level 2) - Previous strategy change didn't work. "
                        "RADICAL CHANGE REQUIRED:\n"
                        "A) Try a completely different cmdlet or .NET method\n"
                        "B) Use run_python instead of run_powershell (or vice versa)\n"
                        "C) Break the task into the absolute minimum viable first step\n"
                        "D) Skip this sub-step and try the next part of your plan"
                    )
                else:
                    return (
                        "[SYSTEM] STUCK DETECTED (Level 3) - Multiple strategy changes failed. "
                        "SKIP THIS STEP. Move on to the next part of your plan. "
                        "Report what you attempted and why it failed."
                    )

        # Oscillating pattern (A-B-A-B)
        if len(self.recent_errors) >= 4:
            last4 = self.recent_errors[-4:]
            if last4[0] == last4[2] and last4[1] == last4[3] and last4[0] != last4[1]:
                self.recent_errors.clear()
                return (
                    "[SYSTEM] OSCILLATION DETECTED - Alternating between two failing approaches. "
                    "STOP BOTH. Use a completely new method:\n"
                    "A) If writing a script, try inline commands instead\n"
                    "B) If using cmdlets, try .NET methods directly\n"
                    "C) Use run_python as an alternative to PowerShell"
                )

        # High error rate
        if len(self.recent_errors) >= 5:
            if all(e for e in self.recent_errors[-5:]):
                self.recent_errors.clear()
                return (
                    "[SYSTEM] HIGH ERROR RATE - Most recent tool calls are failing. "
                    "FULL STOP. Take a step back:\n"
                    "1. Re-read the task requirements\n"
                    "2. What is the simplest possible first step?\n"
                    "3. Execute ONE simple command to verify your environment\n"
                    "4. Then rebuild your approach from that working foundation"
                )

        return None

    def check_write_interceptor(self, path: str, content: str) -> Optional[str]:
        """Block plan/report file writes when user didn't ask for file output."""
        user_lower = self.user_message.lower()

        path_lower = path.lower()
        always_allow_extensions = [
            '.ps1', '.py', '.sh', '.bat', '.cmd', '.json', '.csv', '.log',
            '.xml', '.yaml', '.yml', '.html', '.md', '.txt', '.js', '.ts',
            '.css', '.toml', '.ini', '.cfg', '.conf', '.sql', '.rs', '.go',
        ]
        if any(path_lower.endswith(ext) for ext in always_allow_extensions):
            return None

        file_intent_keywords = [
            'save', 'write to', 'create file', 'output to', 'log to', 'store to',
        ]
        if any(kw in user_lower for kw in file_intent_keywords):
            return None

        content_lower = content.lower()[:500]
        plan_keywords = ['plan', 'report', 'analysis', 'optimization', 'summary', 'result', 'recommendation']
        if any(kw in content_lower for kw in plan_keywords):
            return (
                "[WRITE] BLOCKED - User did not ask for file output. "
                "Present this content directly in your text response instead."
            )

        return None

    def check_tool_repetition(self, tool_name: str, tool_args: dict) -> Optional[str]:
        """Detect repeated identical tool calls."""
        sig = f"{tool_name}:{str(tool_args)[:100]}".lower()
        self.recent_tool_sigs.append(sig)
        if len(self.recent_tool_sigs) > 8:
            self.recent_tool_sigs = self.recent_tool_sigs[-8:]

        if len(self.recent_tool_sigs) >= 3:
            last3 = self.recent_tool_sigs[-3:]
            if len(set(last3)) == 1:
                self.recent_tool_sigs.clear()
                return (
                    "[SYSTEM] REPETITION DETECTED - Same tool called 3x with identical args. "
                    "Result will NOT change. Try a DIFFERENT approach or move to next step."
                )
        return None

    def sanitize_path(self, path: str) -> str:
        """Strip invalid .\\C:\\ prefix from absolute Windows paths."""
        cleaned = re.sub(r'^\.[\\/]([A-Za-z]:\\)', r'\1', path)
        return cleaned

    def check_thinking_only(self, content: str) -> Optional[str]:
        """Detect all-<think> responses and return re-prompt message."""
        if not content:
            return None

        clean = re.sub(r'(?s)<think>.*?</think>', '', content).strip()

        if not clean and '<think>' in content:
            if not self.thinking_reprompted:
                self.thinking_reprompted = True
                return (
                    "[SYSTEM] Your entire response was inside <think> tags and invisible to the user. "
                    "Output your answer as PLAIN VISIBLE TEXT right now."
                )
        return None

    def check_shallow_scan(self, tool_call_count: int) -> Optional[str]:
        """Detect shallow scans and demand deeper analysis."""
        if re.search(r'(?i)(scan deeply|deep scan|thorough|comprehensive)', self.user_message):
            if tool_call_count < 5 and not self.shallow_scan_reprompted:
                self.shallow_scan_reprompted = True
                return (
                    "[SYSTEM] Only {0} tool calls for a deep scan task. NOT thorough enough. "
                    "Execute at least 5 more tool calls to gather CPU, GPU, RAM, disk, network, "
                    "process, service, and registry data."
                ).format(tool_call_count)
        return None

    def check_reasoning_quality(self, content: str) -> Optional[str]:
        """Check if agent is providing reasoning or just dumping tool output."""
        if not content or len(content) < 50:
            return None

        # Check for structured reasoning markers
        has_plan = any(kw in content.lower() for kw in ['plan:', 'step ', 'steps:', '1.', '1)'])
        has_analysis = any(kw in content.lower() for kw in ['because', 'therefore', 'this means', 'indicates'])
        has_verification = any(kw in content.lower() for kw in ['verified', 'confirmed', 'checked', 'verify'])

        # Only nudge if agent has done 10+ tool calls but shows no reasoning structure
        if self.turn_tool_calls >= 10 and not has_plan and not has_analysis:
            return (
                "[SYSTEM] REASONING QUALITY CHECK: You've made {0} tool calls but your responses "
                "lack structured reasoning. For the next response:\n"
                "1. State what you've accomplished so far\n"
                "2. Explain what the tool results mean\n"
                "3. Describe your next steps and why"
            ).format(self.turn_tool_calls)

        return None

    def process_tool_result(self, tool_name: str, stdout: str, stderr: str) -> tuple[str, Optional[str]]:
        """Process a tool result: truncate, analyze stderr, check loops."""
        from config import MAX_OUTPUT_CHARS

        if len(stdout) > MAX_OUTPUT_CHARS:
            stdout = stdout[:MAX_OUTPUT_CHARS] + f"\n... [TRUNCATED at {MAX_OUTPUT_CHARS} chars]"

        hint = None
        loop_msg = None

        if stderr and stderr.strip():
            hint = self.analyze_stderr(stderr)
            loop_msg = self.check_loop_detection(stderr)
            result = f"[STDOUT]\n{stdout}\n[STDERR]\n{stderr}"
            if hint:
                result += f"\n{hint}"
            self.log_tool_result(tool_name, success=False, has_stderr=True)
        else:
            result = stdout if stdout else "(no output)"
            self.log_tool_result(tool_name, success=True, has_stderr=False)

        return result, loop_msg
