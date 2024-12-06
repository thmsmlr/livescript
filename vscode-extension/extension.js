// The module 'vscode' contains the VS Code extensibility API
// Import the module and reference it with the alias vscode in your code below
const vscode = require('vscode');
const net = require('net');
const path = require('path');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');

class LiveScriptConnection {
	constructor() {
		this.connections = new Map(); // filepath -> {socket, reconnectTimer, connected, heartbeatInterval}
		this.reconnectDelay = 2000;
		this.messageHandlers = new Set();
		this.pendingResponses = new Map(); // ref -> {resolve, reject, timeout}
		this.debug = true; // Enable debug logging
		this.HEARTBEAT_INTERVAL = 5000; // Send heartbeat every 5 seconds
	}

	log(message) {
		if (this.debug && outputChannel) {
			outputChannel.appendLine(`[LiveScriptConnection] ${message}`);
		}
	}

	addMessageHandler(handler) {
		this.messageHandlers.add(handler);
	}

	removeMessageHandler(handler) {
		this.messageHandlers.remove(handler);
	}

	// Send a message and wait for its response
	async sendCommandAndWait(filepath, command, timeoutMs = 5000) {
		const ref = crypto.randomBytes(16).toString('hex');
		const commandWithRef = { ...command, ref };

		return new Promise((resolve, reject) => {
			// Set timeout
			const timeout = setTimeout(() => {
				this.pendingResponses.delete(ref);
				reject(new Error(`Command timed out after ${timeoutMs}ms`));
			}, timeoutMs);

			// Store the promise handlers
			this.pendingResponses.set(ref, { resolve, reject, timeout });

			// Send the command
			if (!this.sendMessage(filepath, commandWithRef)) {
				clearTimeout(timeout);
				this.pendingResponses.delete(ref);
				reject(new Error('Failed to send command - not connected'));
			}
		});
	}

	sendMessage(filepath, message) {
		const conn = this.connections.get(filepath);
		if (!conn || !conn.connected) {
			this.log(`Cannot send message - not connected to ${filepath}`);
			return false;
		}

		try {
			conn.socket.write(JSON.stringify(message) + '\n');
			return true;
		} catch (e) {
			this.log(`Error sending message to ${filepath}: ${e.message}`);
			return false;
		}
	}

	startHeartbeat(filepath) {
		const conn = this.connections.get(filepath);
		if (!conn) return;

		// Clear any existing heartbeat interval
		if (conn.heartbeatInterval) {
			clearInterval(conn.heartbeatInterval);
		}

		// Start new heartbeat interval
		conn.heartbeatInterval = setInterval(() => {
			if (conn.connected) {
				this.sendMessage(filepath, { command: 'heartbeat', timestamp: Date.now() });
			}
		}, this.HEARTBEAT_INTERVAL);
	}

	async connect(filepath) {
		// If we have an existing connection, clean it up first
		if (this.connections.has(filepath)) {
			const existingConn = this.connections.get(filepath);
			if (existingConn.reconnectTimer) {
				clearTimeout(existingConn.reconnectTimer);
			}
			if (existingConn.heartbeatInterval) {
				clearInterval(existingConn.heartbeatInterval);
			}
			if (existingConn.socket) {
				existingConn.socket.destroy();
			}
			this.connections.delete(filepath);
		}

		try {
			const port = await getServerPort(filepath);
			const socket = new net.Socket();

			this.connections.set(filepath, {
				socket,
				reconnectTimer: null,
				connected: false,
				heartbeatInterval: null
			});

			socket.on('connect', () => {
				this.log(`Connected to ${filepath}`);
				const conn = this.connections.get(filepath);
				conn.connected = true;

				// Send establish_persistent command
				socket.write(JSON.stringify({
					command: 'establish_persistent',
					filepath: filepath
				}) + '\n');

				// Clear any reconnect timer
				if (conn.reconnectTimer) {
					clearTimeout(conn.reconnectTimer);
					conn.reconnectTimer = null;
				}

				// Start heartbeat
				this.startHeartbeat(filepath);
			});

			socket.on('data', (data) => {
				try {
					const messages = data.toString().split('\n').filter(Boolean);
					messages.forEach(msg => {
						try {
							const parsed = JSON.parse(msg);

							// Check if this is a response to a pending command
							if (parsed.ref && this.pendingResponses.has(parsed.ref)) {
								const { resolve, reject, timeout } = this.pendingResponses.get(parsed.ref);
								clearTimeout(timeout);
								this.pendingResponses.delete(parsed.ref);

								if (parsed.success === false) {
									reject(parsed.error);
								} else {
									resolve(parsed.result);
								}
							} else {
								// Broadcast other messages (like heartbeats) to handlers
								this.broadcast(parsed, filepath);
							}
						} catch (e) {
							this.log(`Error parsing message: ${e.message}`);
						}
					});
				} catch (e) {
					this.log(`Error handling data: ${e.message}`);
				}
			});

			socket.on('error', (err) => {
				this.log(`Socket error for ${filepath}: ${err.message}`);
				this.handleDisconnect(filepath);
			});

			socket.on('close', () => {
				this.log(`Connection closed for ${filepath}`);
				this.handleDisconnect(filepath);
			});

			socket.connect(port, 'localhost');
		} catch (err) {
			this.log(`Failed to connect to ${filepath}: ${err.message}`);
			this.handleDisconnect(filepath);
			throw err; // Propagate the error
		}
	}

	handleDisconnect(filepath) {
		const conn = this.connections.get(filepath);
		if (!conn) return;

		conn.connected = false;

		// Clean up existing socket
		if (conn.socket) {
			conn.socket.destroy();
		}

		// Clear heartbeat interval
		if (conn.heartbeatInterval) {
			clearInterval(conn.heartbeatInterval);
		}

		// Reject any pending responses
		for (const [ref, { resolve, reject, timeout }] of this.pendingResponses.entries()) {
			clearTimeout(timeout);
			reject(new Error('Connection closed'));
			this.pendingResponses.delete(ref);
		}

		// Remove the connection entirely instead of trying to reconnect
		this.connections.delete(filepath);
	}

	disconnect(filepath) {
		const conn = this.connections.get(filepath);
		if (!conn) return;

		if (conn.reconnectTimer) {
			clearTimeout(conn.reconnectTimer);
		}

		if (conn.heartbeatInterval) {
			clearInterval(conn.heartbeatInterval);
		}

		if (conn.socket) {
			conn.socket.destroy();
		}

		// Reject any pending responses
		for (const [ref, { resolve, reject, timeout }] of this.pendingResponses.entries()) {
			clearTimeout(timeout);
			reject(new Error('Connection closed'));
			this.pendingResponses.delete(ref);
		}

		this.connections.delete(filepath);
		this.log(`Disconnected from ${filepath}`);
	}

	disconnectAll() {
		for (const filepath of this.connections.keys()) {
			this.disconnect(filepath);
		}
	}

	broadcast(message, filepath) {
		this.messageHandlers.forEach(handler => {
			try {
				handler(message, filepath);
			} catch (e) {
				this.log(`Error in message handler: ${e.message}`);
			}
		});
	}
}

// Create global instance
global.livescriptConnection = new LiveScriptConnection();

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
	constructor(context) {
		this.codeLenses = [];
		this.expressions = [];
		this._onDidChangeCodeLenses = new vscode.EventEmitter();
		this.onDidChangeCodeLenses = this._onDidChangeCodeLenses.event;
		this.activeConnections = new Map(); // Track filepath -> connection status
	}

	async verifyServerConnection(filepath) {
		const result = await sendCommand({
			command: 'verify_connection',
			filepath: filepath
		});
		return result.connected;
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
				mode: executionMode,
			})
				.then(result => {
					this.expressions = result;
					this.codeLenses = [];

					// Create CodeLenses for each expression
					this.expressions.forEach(expr => {
						const range = new vscode.Range(
							expr.line_start - 1, 0,  // VS Code is 0-based, Elixir is 1-based
							expr.line_start - 1, 0
						);

						if (expr.status === 'executing') {
							const title = 'Running...';

							this.codeLenses.push(new vscode.CodeLens(range, {
								title: title,
							}));
						} else if (expr.status === 'pending') {
							const title = 'Queued...';

							this.codeLenses.push(new vscode.CodeLens(range, {
								title: title,
							}));
						} else {
							const triangle = expr.status === 'executed' ? '▶️' : '▷';
							const title = executionMode === 'block' ?
								`${triangle} Execute Block (⇧⏎)` :
								`${triangle} Execute (⇧⏎)`;

							this.codeLenses.push(new vscode.CodeLens(range, {
								title: title,
								command: 'extension.livescript.run_at_cursor',
								arguments: [{ line: expr.line_start, line_end: expr.line_end }]
							}));
						}

					});

					resolve(this.codeLenses);
				})
				.catch(error => {
					if (response.error?.type === "parse_error") {
						resolve(this.codeLenses);
						return;
					}
					// For other errors, log and clear code lenses
					console.error("Server error:", response.error);
					return;
				});
		});
	}

	refresh() {
		this._onDidChangeCodeLenses.fire();
	}
}

async function sendCommand(command) {
	const filepath = command.filepath || vscode.window.activeTextEditor?.document.fileName;
	if (!filepath) {
		return { success: false, error: 'No active file' };
	}

	try {
		// Ensure we have a connection
		if (!global.livescriptConnection.connections.has(filepath)) {
			await global.livescriptConnection.connect(filepath);
		}

		// Send command and wait for response
		const result = await global.livescriptConnection.sendCommandAndWait(filepath, command);
		return result;
	} catch (err) {
		console.error("Command error:", err);
		return { success: false, error: err.message };
	}
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

	// Check if we already have a vertical split
	const hasVerticalSplit = visibleEditors.some(editor => {
		return editor.viewColumn !== activeEditor.viewColumn &&
			(editor.viewColumn === vscode.ViewColumn.One ||
				editor.viewColumn === vscode.ViewColumn.Two);
	});


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

	// Add default message handler for debugging
	global.livescriptConnection.addMessageHandler((message, filepath) => {
		outputChannel.appendLine(`[Message from ${filepath}] ${JSON.stringify(message, null, 2)}`);

		const provider = getCodeLensProvider();
		if (message.type === 'executing') {
			// Refresh code lenses to update decorations
			provider.provideCodeLenses(vscode.window.activeTextEditor.document)
				.then(codeLenses => {
					provider.refresh();
				});
		} else if (message.type === 'done_executing') {
			// Refresh code lenses to update decorations
			provider.provideCodeLenses(vscode.window.activeTextEditor.document)
				.then(codeLenses => {
					provider.refresh();
				});
		}
	});

	// Watch for file open/close events to manage connections
	context.subscriptions.push(
		vscode.workspace.onDidOpenTextDocument(doc => {
			if (doc.fileName.endsWith('.exs')) {
				global.livescriptConnection.connect(doc.fileName);
			}
		}),
		vscode.workspace.onDidCloseTextDocument(doc => {
			if (doc.fileName.endsWith('.exs')) {
				global.livescriptConnection.disconnect(doc.fileName);
			}
		})
	);

	// Connect to any already open .exs files
	vscode.workspace.textDocuments.forEach(doc => {
		if (doc.fileName.endsWith('.exs')) {
			global.livescriptConnection.connect(doc.fileName);
		}
	});

	// Create the CodeLens provider instance
	const codeLensProvider = new LiveScriptCodeLensProvider(context);
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

			// Disconnect any existing connection first
			global.livescriptConnection.disconnect(filepath);

			// Determine the appropriate view column for the terminal
			const targetColumn = findOrCreateVerticalSplit();

			const terminal = vscode.window.createTerminal({
				name: 'LiveScript',
				location: {
					preserveFocus: true,
					viewColumn: targetColumn
				}
			});

			terminal.sendText(`cd ~ && iex -S mix livescript ${filepath}`);
			terminal.show(true);

			// Wait for server to start and try to connect
			let connected = false;
			for (let i = 0; i < 5; i++) { // Try 5 times
				await new Promise(resolve => setTimeout(resolve, 1000));
				try {
					await global.livescriptConnection.connect(filepath);
					const isConnected = await codeLensProvider.verifyServerConnection(filepath);
					if (isConnected) {
						connected = true;
						break;
					}
				} catch (err) {
					console.log('Connection attempt failed:', err);
					// Continue to next attempt
				}
			}

			if (!connected) {
				vscode.window.showErrorMessage('Failed to connect to LiveScript server after multiple attempts');
				return;
			}

			codeLensProvider.refresh();
		}
	);

	// Register the run_at_cursor command
	let runAtCursorCommand = vscode.commands.registerCommand(
		'extension.livescript.run_at_cursor',
		(options) => {
			const editor = vscode.window.activeTextEditor;
			if (!editor) return;

			const provider = getCodeLensProvider();
			const executionMode = vscode.workspace.getConfiguration('livescript').get('executionMode');

			let line = options.line;
			let line_end = options.line_end;

			if (line === undefined) {
				line = editor.selection.active.line + 1;

				if (editor.selection.isEmpty) {
					// todo: find the line end depending on execution mode
					if (executionMode === 'block') {
						let expr = provider.expressions.find(expr =>
							expr.line_start <= line && expr.line_end >= line
						);
						line = expr.line_start;
						line_end = expr.line_end;
					} else {
						line_end = line;
					}
				} else {
					line = editor.selection.start.line + 1;
					line_end = editor.selection.end.line + 1;
				}
			}
			if (!line_end) { line_end = line; }

			const code = editor.document.getText();

			// Send the appropriate command based on execution mode
			sendCommand({
				command: 'run_at_cursor',
				code: code,
				line: line,
				line_end: line_end,
			});

			// Move cursor to next expression if specified
			if (options?.moveCursorToNextExpression) {
				const nextExpr = findNextExpression(provider.expressions, line_end);
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

	// Add cleanup on deactivation
	context.subscriptions.push({
		dispose: () => {
			global.livescriptConnection.disconnectAll();
		}
	});

	// Add the subscriptions to context
	context.subscriptions.push(
		disposableProvider,
		disposableAfterCursor,
		disposableSelectionChange,
		startServerCommand,
		runAtCursorCommand
	);
}

// this method is called when your extension is deactivated
function deactivate() { }

// eslint-disable-next-line no-undef
module.exports = {
	activate,
	deactivate
}
