// Reports this window's terminals to the Waiting menu bar app, and selects one when the app opens
// `<scheme>://waitingdev.waiting/show?pid=<shell pid>&windowId=<id>`.
//
// Each window writes a state file to ~/Library/Application Support/dev.waiting.mac/vscode/,
// named after its extension host's PID, and keeps it up to date:
//   { uriScheme, hostPid, focused, activeTerminalPid, terminalPids, showURI }
// `showURI` comes from `asExternalUri`, which adds this window's `windowId`, so VS Code routes it
// to this window and focuses the window once the URI is handled.

const fs = require("fs");
const os = require("os");
const path = require("path");
const vscode = require("vscode");

const directory = path.join(os.homedir(), "Library", "Application Support", "dev.waiting.mac", "vscode");
const stateFile = path.join(directory, `${vscode.env.uriScheme}-${process.pid}.json`);

let showURI;
let writes = Promise.resolve();

async function activate(context) {
    context.subscriptions.push(
        vscode.window.registerUriHandler({ handleUri: show }),
        vscode.window.onDidChangeWindowState(update),
        vscode.window.onDidChangeActiveTerminal(update),
        vscode.window.onDidOpenTerminal(update),
        vscode.window.onDidCloseTerminal(update),
    );
    const base = vscode.Uri.parse(`${vscode.env.uriScheme}://waitingdev.waiting/show`);
    showURI = (await vscode.env.asExternalUri(base)).toString(true);
    update();
}

function deactivate() {
    try {
        fs.unlinkSync(stateFile);
    } catch {}
}

async function show(uri) {
    const pid = Number(new URLSearchParams(uri.query).get("pid"));
    for (const terminal of vscode.window.terminals) {
        if ((await terminal.processId) === pid) {
            terminal.show(false);
            return;
        }
    }
}

// Writes are chained so a slow `processId` lookup can't make an older state land last.
function update() {
    writes = writes.then(write, write);
}

async function write() {
    if (showURI === undefined) return;
    const terminalPids = (await Promise.all(vscode.window.terminals.map((t) => t.processId)))
        .filter((pid) => pid !== undefined);
    const state = {
        uriScheme: vscode.env.uriScheme,
        hostPid: process.pid,
        focused: vscode.window.state.focused,
        activeTerminalPid: (await vscode.window.activeTerminal?.processId) ?? null,
        terminalPids,
        showURI,
    };
    try {
        fs.mkdirSync(directory, { recursive: true });
        const temporary = `${stateFile}.tmp`;
        fs.writeFileSync(temporary, JSON.stringify(state));
        fs.renameSync(temporary, stateFile);
    } catch (error) {
        console.error(`waiting: could not write ${stateFile}: ${error}`);
    }
}

module.exports = { activate, deactivate };
