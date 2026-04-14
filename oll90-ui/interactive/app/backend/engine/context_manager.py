"""Context window management v3 - smart summarization and token tracking for 65K window"""
import re
from typing import Optional

from config import CONTEXT_WINDOW, COMPACTION_THRESHOLD


class ContextManager:
    def __init__(self, max_tokens: int = CONTEXT_WINDOW, compact_at: float = COMPACTION_THRESHOLD):
        self.max_tokens = max_tokens
        self.compact_threshold = int(max_tokens * compact_at)
        self.total_prompt_tokens = 0
        self.total_completion_tokens = 0
        self.compaction_count = 0

    def estimate_tokens(self, messages: list[dict]) -> int:
        """Rough estimate: total chars / 3.5 for Qwen tokenizer."""
        total_chars = sum(len(m.get("content", "")) for m in messages)
        return int(total_chars / 3.5)

    def update_from_response(self, prompt_eval_count: int = 0, eval_count: int = 0):
        """Update token counts from Ollama streaming response metrics."""
        if prompt_eval_count:
            self.total_prompt_tokens = prompt_eval_count
        if eval_count:
            self.total_completion_tokens += eval_count

    def needs_compaction(self, messages: list[dict]) -> bool:
        """Check if we should compact based on actual or estimated tokens."""
        if self.total_prompt_tokens > 0:
            return self.total_prompt_tokens > self.compact_threshold
        return self.estimate_tokens(messages) > self.compact_threshold

    def compact(self, messages: list[dict]) -> list[dict]:
        """Smart compaction: summarize by task segments, preserve key findings.

        Strategy:
        - Keep system message (always first)
        - Summarize middle messages by grouping user requests + agent responses
        - Preserve recent context (last 20 messages for better continuity)
        - Keep key tool results (errors, important findings)
        """
        self.compaction_count += 1
        keep_first = 1  # System message
        keep_last = 20  # Recent context

        if len(messages) <= keep_first + keep_last:
            return messages

        middle = messages[keep_first:-keep_last]

        # Build structured summary
        summary_parts = [
            f"=== CONVERSATION SUMMARY (compaction #{self.compaction_count}) ===",
            f"Original messages: {len(middle)} summarized below.",
            ""
        ]

        # Group messages into task segments (user message + following responses)
        current_task = None
        task_tools = []
        task_errors = []
        task_findings = []

        for m in middle:
            role = m.get("role", "")
            content = m.get("content", "")

            if role == "user":
                # Flush previous task
                if current_task:
                    task_summary = f"TASK: {current_task[:200]}"
                    if task_tools:
                        task_summary += f"\n  Tools used: {', '.join(task_tools[:10])}"
                    if task_errors:
                        task_summary += f"\n  Errors encountered: {'; '.join(task_errors[:3])}"
                    if task_findings:
                        task_summary += f"\n  Key findings: {'; '.join(task_findings[:3])}"
                    summary_parts.append(task_summary)
                    summary_parts.append("")

                current_task = content[:300].replace('\n', ' ')
                task_tools = []
                task_errors = []
                task_findings = []

            elif role == "assistant" and content:
                clean = re.sub(r'(?s)<think>.*?</think>', '', content).strip()
                if clean:
                    # Extract key findings (lines with numbers, paths, or key: value patterns)
                    for line in clean.split('\n')[:10]:
                        line = line.strip()
                        if line and (
                            re.search(r'\d+\.\d+', line) or  # numbers
                            re.search(r'[A-Z]:\\', line) or  # paths
                            re.search(r'\w+:\s+\S', line) or  # key: value
                            'VERIFIED' in line or 'COMPLETE' in line
                        ):
                            task_findings.append(line[:150])
                            if len(task_findings) >= 3:
                                break

            elif role == "tool" and content:
                # Extract tool name from context
                if content.startswith("[STDOUT]") or content.startswith("[STDERR]"):
                    if "[STDERR]" in content:
                        err_preview = content.split("[STDERR]")[1][:100].strip()
                        if err_preview:
                            task_errors.append(err_preview)
                    task_tools.append("tool_call")
                else:
                    preview = content[:80].replace('\n', ' ')
                    task_tools.append(preview[:30])

            elif role == "system" and content:
                # Keep system hints (STUCK, REFLECTION, etc.)
                if any(kw in content for kw in ['STUCK', 'REFLECTION', 'LOOP', 'OSCILLATION']):
                    summary_parts.append(f"SYSTEM: {content[:200]}")

        # Flush last task
        if current_task:
            task_summary = f"TASK: {current_task[:200]}"
            if task_tools:
                task_summary += f"\n  Tools used: {', '.join(task_tools[:10])}"
            if task_errors:
                task_summary += f"\n  Errors: {'; '.join(task_errors[:3])}"
            if task_findings:
                task_summary += f"\n  Findings: {'; '.join(task_findings[:3])}"
            summary_parts.append(task_summary)

        summary_parts.append("")
        summary_parts.append("=== END SUMMARY ===")
        summary = "\n".join(summary_parts)

        # Rebuild messages
        result = [messages[0]]  # System message
        result.append({"role": "user", "content": summary})
        result.extend(messages[-keep_last:])

        return result

    def get_usage_str(self) -> str:
        """Return human-readable token usage string."""
        if self.total_prompt_tokens > 0:
            used = self.total_prompt_tokens
        else:
            used = 0
        pct = round(used / self.max_tokens * 100) if self.max_tokens else 0
        return f"~{used // 1000}K/{self.max_tokens // 1000}K tokens ({pct}%)"
