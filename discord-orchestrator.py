#!/usr/bin/env python3
"""
discord-orchestrator.py
Discord-based Agent Orchestration - Orchestrator Bridge

This script acts as the bridge between Discord messages and the worker spawning system.
It receives tasks from Discord, spawns workers via spawn-worker.sh, and posts results back.

Usage:
    python discord-orchestrator.py --task-id <uuid> --channel <channel_id> --task "description"

Environment Variables:
    DISCORD_BOT_TOKEN - Bot token for posting results
    DISCORD_GUILD_ID  - Server ID where channels exist
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, Optional, Tuple


class DiscordOrchestrator:
    """Orchestrator that spawns workers and coordinates via Discord."""
    
    def __init__(self, config: Dict):
        self.config = config
        self.script_dir = Path(__file__).parent
        self.workspace_base = Path.home() / ".openclaw" / "discord-workers"
        
    def spawn_worker(
        self,
        task_id: str,
        task_description: str,
        model: str,
        thinking: str
    ) -> Tuple[bool, Dict]:
        """
        Spawn a worker process for the given task.
        
        Returns:
            (success: bool, result: dict)
        """
        spawn_script = self.script_dir / "spawn-worker.sh"
        
        if not spawn_script.exists():
            return False, {"error": f"Spawn script not found: {spawn_script}"}
        
        # Build command
        cmd = [
            str(spawn_script),
            "--task-id", task_id,
            "--task", task_description,
            "--model", model,
            "--thinking", thinking
        ]
        
        print(f"[Orchestrator] Spawning worker for task {task_id}")
        print(f"[Orchestrator] Model: {model}, Thinking: {thinking}")
        
        try:
            # Run spawn script
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=600  # 10 minute total timeout
            )
            
            # Read result.json
            result_path = self.workspace_base / task_id / "result.json"
            if result_path.exists():
                with open(result_path) as f:
                    worker_result = json.load(f)
                
                success = worker_result.get("status") in ["success", "completed"]
                return success, worker_result
            else:
                return False, {
                    "error": "No result file generated",
                    "exit_code": result.returncode,
                    "stderr": result.stderr
                }
                
        except subprocess.TimeoutExpired:
            return False, {"error": "Worker spawn timed out"}
        except Exception as e:
            return False, {"error": str(e)}
    
    def select_model_and_thinking(self, task_description: str) -> Tuple[str, str]:
        """
        Select appropriate model and thinking level for the task.
        
        MVP: Simple keyword matching. In the future, this could use LLM to classify.
        """
        task_lower = task_description.lower()
        
        # Complex tasks
        complex_indicators = [
            "architecture", "design", "refactor", "review", "analyze",
            "optimize", "debug", "complex", "performance", "security"
        ]
        
        # Simple tasks
        simple_indicators = [
            "typo", "fix", "update", "simple", "minor", "quick",
            "documentation", "comment", "readme", "format"
        ]
        
        # Check complexity
        is_complex = any(ind in task_lower for ind in complex_indicators)
        is_simple = any(ind in task_lower for ind in simple_indicators)
        
        if is_complex:
            return "anthropic/claude-sonnet-4", "high"
        elif is_simple:
            return "openrouter/moonshotai/kimi-k2.5", "low"
        else:
            # Default
            return "openrouter/moonshotai/kimi-k2.5", "medium"
    
    def format_discord_message(self, task_id: str, result: Dict) -> str:
        """Format worker result for Discord posting."""
        status = result.get("status", "unknown")
        message = result.get("message", "No message")
        model = result.get("model", "unknown")
        thinking = result.get("thinking", "unknown")
        
        # Status emoji
        emoji = {
            "success": "✅",
            "completed": "✅",
            "partial": "⚠️",
            "failed": "❌",
            "error": "❌",
            "timeout": "⏱️"
        }.get(status, "❓")
        
        output = f"""{emoji} **Task Complete** `{task_id[:8]}`
**Status:** {status.upper()}
**Model:** {model} ({thinking} thinking)
**Summary:** {message}
"""
        
        # Add deliverables if present
        deliverables = result.get("output")
        if deliverables and deliverables != "None":
            output += f"\n**Deliverables:** {deliverables}"
        
        # Add error details if failed
        if status in ["failed", "error"] and "error" in result:
            output += f"\n**Error:** {result['error']}"
        
        return output
    
    def run_task(self, task_id: str, task_description: str) -> Dict:
        """
        Main entry point: receive task, spawn worker, return result.
        """
        print(f"\n{'='*60}")
        print(f"[Orchestrator] New Task: {task_id}")
        print(f"[Orchestrator] Description: {task_description[:100]}...")
        print(f"{'='*60}\n")
        
        # Select model and thinking
        model, thinking = self.select_model_and_thinking(task_description)
        print(f"[Orchestrator] Selected: {model} with {thinking} thinking")
        
        # Spawn worker
        success, result = self.spawn_worker(
            task_id=task_id,
            task_description=task_description,
            model=model,
            thinking=thinking
        )
        
        # Format result
        result["discord_message"] = self.format_discord_message(task_id, result)
        result["success"] = success
        
        return result


def main():
    parser = argparse.ArgumentParser(
        description="Discord Orchestrator - Spawn workers and coordinate tasks"
    )
    parser.add_argument(
        "--task-id",
        required=True,
        help="Unique task identifier"
    )
    parser.add_argument(
        "--task",
        required=True,
        help="Task description"
    )
    parser.add_argument(
        "--model",
        help="Override model selection"
    )
    parser.add_argument(
        "--thinking",
        choices=["off", "minimal", "low", "medium", "high", "xhigh"],
        help="Override thinking level"
    )
    parser.add_argument(
        "--output",
        help="Output file for result (default: stdout)"
    )
    
    args = parser.parse_args()
    
    # Initialize orchestrator
    orchestrator = DiscordOrchestrator(config={})
    
    # Run task
    result = orchestrator.run_task(
        task_id=args.task_id,
        task_description=args.task
    )
    
    # Override if specified
    if args.model:
        result["model"] = args.model
    if args.thinking:
        result["thinking"] = args.thinking
    
    # Output result
    output = json.dumps(result, indent=2)
    
    if args.output:
        with open(args.output, 'w') as f:
            f.write(output)
        print(f"\n[Orchestrator] Result written to: {args.output}")
    else:
        print("\n" + "="*60)
        print("RESULT:")
        print("="*60)
        print(output)
    
    print("\n[Orchestrator] Discord Message:")
    print("-" * 60)
    print(result["discord_message"])
    
    # Exit with appropriate code
    sys.exit(0 if result["success"] else 1)


if __name__ == "__main__":
    main()
