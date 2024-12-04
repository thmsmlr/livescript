// The module 'vscode' contains the VS Code extensibility API
// Import the module and reference it with the alias vscode in your code below
const vscode = require('vscode');
const net = require('net');
const path = require('path');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');

// Add at the top level with other constants
let outputChannel;

// Helper function to find the next expression after the current line
function findNextExpression(expressions, currentLine) {
	// Sort expressions by start line
	const sortedExprs = [...expressions].sort((a, b) => a.line_start - b.line_start);
	// Find the next expression after current line
	return sortedExprs.find(expr => expr.line_start > currentLine);
}

function getPortFilePath(filepath) {
	const hash = crypto.createHash('md5').update(filepath).digest('hex');
	return path.join(os.tmpdir(), `livescript_${hash}.port`);
}

async function getServerPort(filepath) {
	const portFile = getPortFilePath(filepath);
	try {
		const port = await fs.promises.readFile(portFile, 'utf8');
		return parseInt(port.trim(), 10);
	} catch (err) {
		throw new Error(`Could not read LiveScript server port: ${err.message}`);
	}
}

// Define the CodeLens provider
class LiveScriptCodeLensProvider {
	constructor() {
		this.codeLenses = [];
		this.expressions = [];
		this._onDidChangeCodeLenses = new vscode.EventEmitter();
		this.onDidChangeCodeLenses = this._onDidChangeCodeLenses.event;
		this.activeConnections = new Map(); // Track filepath -> connection status
	}

	// Add verifyServerConnection method
	async verifyServerConnection(filepath) {
		return new Promise((resolve) => {
			sendCommand({
				command: 'verify_connection',
				filepath: filepath
			}, (response) => {
				const isConnected = response.success && response.result.connected;
				this.activeConnections.set(filepath, isConnected);
				resolve(isConnected);
			});
		});
	}

	// Update provideCodeLenses
	async provideCodeLenses(document, token) {
		if (!document.fileName.endsWith('.exs')) {
			return [];
		}

		const isConnected = await this.verifyServerConnection(document.fileName);
		if (!isConnected) {
			// Show "Start Server" lens if not connected
			const range = new vscode.Range(0, 0, 0, 0);
			return [new vscode.CodeLens(range, {
				title: '⚡ Start LiveScript Server',
				command: 'extension.livescript.start_server',
				arguments: [{ filepath: document.fileName }]
			})];
		}

		return new Promise((resolve, reject) => {
			const code = document.getText();
			const executionMode = vscode.workspace.getConfiguration('livescript').get('executionMode');

			// Send code to Elixir server for parsing with block mode enabled if in block mode
			sendCommand({
				command: 'parse_code',
				code: code,
				block_mode: executionMode === 'block'
			}, (response) => {
				if (!response.success) {
					// Check if this is a parse error
					if (response.error?.type === "parse_error") {
						console.log("Code parse error - maintaining previous code lens state");
						resolve(this.codeLenses);
						return;
					}
					// For other errors, log and clear code lenses
					console.error("Server error:", response.error);
					resolve([]);
					return;
				}

				this.expressions = response.result;
				this.codeLenses = [];

				// Create CodeLenses for each expression
				this.expressions.forEach(expr => {
					const range = new vscode.Range(
						expr.line_start - 1, 0,  // VS Code is 0-based, Elixir is 1-based
						expr.line_start - 1, 0
					);

					const title = executionMode === 'block' ? 
						'▷ Execute Block (⇧⏎)' : 
						'▷ Execute (⇧⏎)';

					this.codeLenses.push(new vscode.CodeLens(range, {
						title: title,
						command: 'extension.livescript.run_at_cursor',
						arguments: [{ line: expr.line_start }]
					}));
				});

				resolve(this.codeLenses);
			});
		});
	}

	refresh() {
		this._onDidChangeCodeLenses.fire();
	}
}

function sendCommand(command, callback) {
	const filepath = command.filepath || vscode.window.activeTextEditor?.document.fileName;
	if (!filepath) {
		if (callback) callback({ success: false, error: 'No active file' });
		return;
	}

	getServerPort(filepath).then(port => {
		const client = new net.Socket();
		let responseData = '';

		client.connect(port, 'localhost', () => {
			client.write(JSON.stringify(command) + '\n');
		});

		client.on('data', (data) => {
			responseData += data.toString();
		});

		client.on('end', () => {
			try {
				const response = JSON.parse(responseData);
				if (callback) callback(response);
			} catch (e) {
				console.error("Failed to parse response:", e);
				if (callback) callback({ success: false, error: e.message });
			}
		});

		client.on('error', (err) => {
			log(`Socket error: ${err}`);
			console.error("Socket error:", err);
			if (callback) callback({ success: false, error: err.message });
		});
	}).catch(err => {
		console.error("Port lookup error:", err);
		if (callback) callback({ success: false, error: err.message });
	});
}

function sendCommandIfConnected(command, callback) {
	const filepath = command.filepath || vscode.window.activeTextEditor?.document.fileName;
	const provider = getCodeLensProvider();

	if (!filepath || !provider.activeConnections.get(filepath)) {
		vscode.window.showErrorMessage('LiveScript server not connected. Please start the server first.');
		if (callback) callback({ success: false, error: 'Not connected' });
		return;
	}

	sendCommand({ ...command, filepath }, callback);
}

// Helper to get provider instance
function getCodeLensProvider() {
	// We'll need to store the provider instance somewhere accessible
	// This could be in extension state or as a module-level variable
	return global.livescriptProvider;
}

// Add this helper function at the top level
function findOrCreateVerticalSplit() {
	const activeEditor = vscode.window.activeTextEditor;
	if (!activeEditor) return;

	// Get all visible editors
	const visibleEditors = vscode.window.visibleTextEditors;
	log(`visibleEditors: ${visibleEditors}`);

	// Check if we already have a vertical split
	const hasVerticalSplit = visibleEditors.some(editor => {
		return editor.viewColumn !== activeEditor.viewColumn &&
			(editor.viewColumn === vscode.ViewColumn.One ||
				editor.viewColumn === vscode.ViewColumn.Two);
	});

	log(`hasVerticalSplit: ${hasVerticalSplit}`);

	// If we have a vertical split, find the empty column
	if (hasVerticalSplit) {
		return activeEditor.viewColumn === vscode.ViewColumn.One ?
			vscode.ViewColumn.Two :
			vscode.ViewColumn.One;
	}

	// If no split exists, create one in the second column
	vscode.commands.executeCommand('workbench.action.splitEditor');
	return vscode.ViewColumn.Two;
}

// Add this helper function to use throughout your code
function log(message) {
	if (outputChannel) {
		outputChannel.appendLine(message);
	}
}

/**
 * @param {vscode.ExtensionContext} context
 */
function activate(context) {
	// Create output channel
	outputChannel = vscode.window.createOutputChannel('LiveScript', 'livescript-output');
	context.subscriptions.push(outputChannel);

	// Create the CodeLens provider instance
	const codeLensProvider = new LiveScriptCodeLensProvider();
	global.livescriptProvider = codeLensProvider; // Store for access

	// Watch for configuration changes
	context.subscriptions.push(
		vscode.workspace.onDidChangeConfiguration(event => {
			if (event.affectsConfiguration('livescript.executionMode')) {
				codeLensProvider.refresh();
			}
		})
	);

	// Add command for starting the server
	const startServerCommand = vscode.commands.registerCommand(
		'extension.livescript.start_server',
		async (options) => {
			const filepath = options.filepath;

			// Determine the appropriate view column for the terminal
			const targetColumn = findOrCreateVerticalSplit();
			console.log(`Creating terminal in column ${targetColumn}`);

			const terminal = vscode.window.createTerminal({
				name: 'LiveScript',
				location: {
					preserveFocus: true,
					viewColumn: targetColumn
				}
			});

			terminal.sendText(`cd ~ && iex -S mix livescript ${filepath}`);
			terminal.show(true);

			// Wait a bit for server to start, then verify connection
			await new Promise(resolve => setTimeout(resolve, 1000));
			await codeLensProvider.verifyServerConnection(filepath);
			codeLensProvider.refresh();
		}
	);

	// Register the run_at_cursor command
	let runAtCursorCommand = vscode.commands.registerCommand(
		'extension.livescript.run_at_cursor',
		(options) => {
			const editor = vscode.window.activeTextEditor;
			if (!editor) return;

			let line = options.line;
			if (line === undefined) {
				line = editor.selection.active.line + 1;
			}

			const code = editor.document.getText();
			const executionMode = vscode.workspace.getConfiguration('livescript').get('executionMode');

			// Send the appropriate command based on execution mode
			sendCommandIfConnected({
				command: 'run_at_cursor',
				code: code,
				line: line,
				mode: executionMode === 'block' ? 'block' : 'expression'
			});

			// Move cursor to next expression if specified
			if (options?.moveCursorToNextExpression) {
				const provider = getCodeLensProvider();
				const nextExpr = findNextExpression(provider.expressions, line);
				if (nextExpr) {
					const newPosition = new vscode.Position(nextExpr.line_start - 1, 0);
					editor.selection = new vscode.Selection(newPosition, newPosition);
					
					// Reveal the new position in the middle of the viewport
					const range = new vscode.Range(newPosition, newPosition);
					editor.revealRange(range, vscode.TextEditorRevealType.InCenterIfOutsideViewport);
				}
			}
		}
	);

	// Add command for Ctrl+Shift+Enter keyboard shortcut (run_after_cursor)
	const disposableAfterCursor = vscode.commands.registerCommand(
		'extension.livescript.run_after_cursor',
		(options) => {
			let line = options.line;
			if (line === undefined) { line = vscode.window.activeTextEditor.selection.active.line + 1; }
			const code = vscode.window.activeTextEditor.document.getText();
			sendCommand({ command: 'run_after_cursor', code: code, line: line });
		}
	);

	// Register the CodeLens provider with the event handler
	const disposableProvider = vscode.languages.registerCodeLensProvider(
		{ scheme: 'file', language: 'elixir' },
		codeLensProvider
	);

	// Add selection change event listener
	const disposableSelectionChange = vscode.window.onDidChangeTextEditorSelection(event => {
		if (event.textEditor === vscode.window.activeTextEditor) {
			codeLensProvider.refresh();
		}
	});

	// Register the run_block_at_cursor command
	let runBlockAtCursorCommand = vscode.commands.registerCommand(
		'extension.livescript.run_block_at_cursor',
		(options) => {
			const editor = vscode.window.activeTextEditor;
			if (!editor) return;

			const line = options?.line || (editor.selection.active.line + 1);
			const code = editor.document.getText();

			sendCommandIfConnected({
				command: 'run_at_cursor',
				code: code,
				line: line,
				mode: 'block'
			});
		}
	);

	// Add the subscriptions to context
	context.subscriptions.push(
		disposableProvider,
		disposableAfterCursor,
		disposableSelectionChange,
		startServerCommand,
		runAtCursorCommand,
		runBlockAtCursorCommand
	);
}

// this method is called when your extension is deactivated
function deactivate() { }

// eslint-disable-next-line no-undef
module.exports = {
	activate,
	deactivate
}
