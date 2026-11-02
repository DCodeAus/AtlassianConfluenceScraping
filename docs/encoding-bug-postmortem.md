# What Happened: `repair_garbled_text.ps1` Broke Itself

Short version: the script whose entire job is fixing encoding bugs got taken out by an encoding bug. In its own source code. I promise that's funnier than it is embarrassing, but it's a bit of both.

## The report

One of the team ran `repair_garbled_text.ps1` and got this:

```
Cannot convert value "[garbled nonsense]" to type "System.Text.RegularExpressions.Regex".
Error: "parsing [garbled nonsense] - [x-y] range in reverse order."
```

First reaction: that's a weird one. Second reaction, a few seconds later, looking closer at the garbled text in the error message itself: *hang on, that looks exactly like the mojibake this script exists to clean up.*

## Working it out

The regex that builds the "does this still look garbled" health check has a character range in it - `[Â-ô]`, which is shorthand for "any of these accented letters, covering the whole range." Two literal special characters, typed straight into the script.

That's normally fine. PowerShell doesn't care about accented characters in a script any more than it cares about the word "café" in a string. Except - and this is the bit I'd never had to think about before - a `.ps1` file needs to actually be *read* correctly before any of that matters. And Windows PowerShell 5.1 has an old habit: if a script file doesn't start with a tiny invisible marker called a BOM (byte order mark) saying "this is UTF-8," it doesn't assume UTF-8. It guesses, using whatever the local Windows install's default text encoding is set to.

Our script file didn't have that marker. On a machine where the guess landed on something other than UTF-8, the two accented characters in the regex got misread as a completely different, garbage sequence of characters before the script even started running - which is exactly why the error message itself was full of nonsense. The regex wasn't broken. The bytes describing the regex got corrupted on the way in, before PowerShell ever got a chance to parse them as intended.

So: the script built to repair "Confluence sent UTF-8, PowerShell read it as something else" mojibake got hit by the literal same failure mode, just happening to its own source file instead of Confluence's content. Same bug, different victim.

## The fix

Two parts, one obvious once you see it, one just being thorough:

1. **Stopped typing the special characters directly into the script.** Instead of writing `Â` and `ô` as literal characters, I build them from their character codes at runtime (`[char]0x00C2`, that sort of thing). A number like `0x00C2` can't get misread - it's plain ASCII regardless of what encoding guess a computer makes. This is the actual fix; everything else is belt-and-suspenders.

2. **Added the missing BOM to every `.ps1` file in the project**, not just the one that broke. Belt and suspenders, because there's no guarantee some future edit doesn't introduce another literal special character somewhere, and the BOM means PowerShell 5.1 will always read the file correctly regardless of what the underlying machine happens to be set to.

While auditing for this, I found the exact same landmine sitting in `confluence_sharepoint_paste.ps1` too - the ☑/☐ checkbox characters used for task lists were typed literally as well. That one hadn't crashed anything (yet), it would've just silently corrupted the pasted HTML output on the wrong machine. Fixed the same way.

## Proving it actually works

Didn't want to just "fix it and hope." Actually simulated the failure:

- Took the real script file, stripped its BOM, decoded the bytes as the wrong encoding (recreating exactly what a misconfigured machine does), and confirmed the resulting file still parses.
- Then actually *ran* that broken-encoding version against real test content end to end, and confirmed it still worked correctly - repaired what it should, flagged what it couldn't, didn't false-positive on clean content.
- Also specifically tested the "copy the code off GitHub, paste into a text file, rename to `.ps1`" workflow, since that's a realistic way this file ends up on someone's machine - copy-pasting drops the BOM entirely. Still worked, because the actual fix (building characters from codes) doesn't depend on the BOM being there at all. The BOM is insurance, not the load-bearing part.

## Stopping it from happening again

Manually checking every script for stray literal special characters worked this once, but it's not something anyone's going to remember to do by hand every time a script gets edited. So I added `check_script_encoding.ps1` - a small standalone tool that scans every `.ps1` file in the folder for exactly these two things (missing BOM, literal special character sitting in actual code rather than built from a code), and fails loudly if it finds either.

Ran it against five deliberately constructed test cases (no BOM, a bad character in real code, a bad character safely inside a comment twice over, and a fully clean file) to make sure it flags the two real problems and stays quiet on the three safe ones. It does. Then ran it against all six of the actual pipeline scripts - clean.

## The lesson

If your tool's whole purpose is fixing an encoding problem, don't assume that tool is somehow immune to the same problem. Should've had the BOM on every script from day one - it's a five-second fix that would've prevented this outright. Filed away for next time: any script with literal special characters in it needs a BOM, full stop, before it goes near a machine I don't control.
