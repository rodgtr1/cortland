/**
 * Permission Gate Extension
 *
 * Prompts for confirmation before running bash commands that could destroy
 * files in the working directory. Scoped to project-level destruction —
 * disk/partition/system-level commands are left out of scope.
 *
 * In non-interactive mode (no UI), dangerous commands are blocked by default.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { closeSync, openSync, writeSync } from "node:fs";

const TERMPROP = "vte.ext.cortland.agent";
function report(status: "busy" | "ready"): void {
  try {
    const fd = openSync("/dev/tty", "w");
    try { writeSync(fd, `\x1b]666;${TERMPROP}=${status}\x1b\\`); }
    finally { closeSync(fd); }
  } catch { /* no controlling terminal */ }
}

export default function (pi: ExtensionAPI) {
	const dangerousPatterns: RegExp[] = [
		// Recursive / forced removal (catches plain `rm -r`, not just `-rf`)
		/\brm\b[^\n]*\s-(?:[a-z]*r[a-z]*|-recursive)\b/i,
		/\brm\b[^\n]*\s-(?:[a-z]*f[a-z]*|-force)\b/i,
		// rm targeting risky roots even without flags
		/\brm\b[^\n]*\s(?:\/|~|\$HOME|\.\.?)(?:\s|\/|$)/i,

		// find ... -delete  /  find ... -exec rm
		/\bfind\b[^\n]*-delete\b/i,
		/\bfind\b[^\n]*-exec\b[^\n]*\brm\b/i,

		// Secure / forced deletion utilities (srm removed from macOS since Sierra)
		/\b(?:shred|wipe|srm)\b/i,
		// truncate can zero out files
		/\btruncate\b/i,

		// Output redirection that overwrites (single >, not appending >>)
		// Excludes >> and >& ; flags /dev/null specially below is unnecessary
		/(?<![>&\d])>(?!>)\s*\S/,
		// tee without -a overwrites its target files
		/\btee\b(?![^\n]*\s-a\b)[^\n]*\s\S/i,

		// Privilege escalation
		/\bsudo\b/i,
		/\bdoas\b/i,
		/\bsu\b(?:\s|$)/i,

		// Broad permission/ownership changes
		/\b(?:chmod|chown)\b[^\n]*\s-(?:[a-z]*R[a-z]*|-recursive)\b/i,
		/\b(?:chmod|chown)\b[^\n]*\b(?:777|000)\b/i,

		// Git operations that discard work
		/\bgit\b[^\n]*\breset\b[^\n]*--hard\b/i,
		/\bgit\b[^\n]*\bclean\b[^\n]*-[a-z]*f/i,
		/\bgit\b[^\n]*\bcheckout\b[^\n]*--\s*\.?\s*$/i,
		/\bgit\b[^\n]*\bpush\b[^\n]*(?:--force\b|-[a-z]*f\b)/i,

		// Fetch-and-execute (a remote payload could do anything inside the mount)
		/\b(?:curl|wget)\b[^\n]*\|\s*(?:ba)?sh\b/i,

		// Fork bomb
		/:\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:/,
	];

	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return undefined;

		const command = event.input.command as string;
		const matched = dangerousPatterns.find((p) => p.test(command));
		if (!matched) return undefined;

		if (!ctx.hasUI) {
			// Non-interactive: block by default, nothing to confirm against.
			return { block: true, reason: "Dangerous command blocked (no UI for confirmation)" };
		}

		report("ready");
		const choice = await ctx.ui.select(
			`⚠️ Potentially destructive command:\n\n  ${command}\n\nAllow?`,
			["Yes", "No"],
		);
		report("busy");

		if (choice !== "Yes") {
			return { block: true, reason: "Blocked by user" };
		}

		return undefined;
	});
}
