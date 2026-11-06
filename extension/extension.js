'use strict';

const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const argv = require('./argv');

const POLL_INTERVAL = 1500;

function argvFile() {
  if (process.env.VSCODE_PORTABLE) return path.join(process.env.VSCODE_PORTABLE, 'argv.json');
  const product = JSON.parse(fs.readFileSync(path.join(vscode.env.appRoot, 'product.json'), 'utf8'));
  return path.join(os.homedir(), product.dataFolderName, 'argv.json');
}

function buildPageScript(buttons) {
  const labels = buttons.map((label) => String(label).replace(/\s+/g, ' ').trim().toLowerCase());
  const key = JSON.stringify(labels);
  return `(() => {
    const key = ${JSON.stringify(key)};
    const labels = ${key};
    let state = window.__antigravityAutoClick;
    if (!state || state.key !== key) {
      if (state) state.stop();
      const lastClicked = new WeakMap();
      const clicks = [];
      const normalize = (text) => text.replace(/\\s+/g, ' ').trim().toLowerCase();
      let lastScan = 0;
      let pending = null;
      const scan = () => {
        lastScan = Date.now();
        if (Date.now() - state.alive > 10000) return;
        for (const button of document.querySelectorAll('button, [role="button"]')) {
          const text = button.textContent || '';
          if (text.length > 60 || !labels.includes(normalize(text))) continue;
          if (button.disabled || button.getAttribute('aria-disabled') === 'true') continue;
          const previous = lastClicked.get(button);
          if (previous && Date.now() - previous < 2500) continue;
          lastClicked.set(button, Date.now());
          button.click();
          clicks.push(text.trim());
        }
      };
      const observer = new MutationObserver(() => {
        if (Date.now() - lastScan >= 150) scan();
        else if (!pending) pending = setTimeout(() => { pending = null; scan(); }, 160);
      });
      observer.observe(document, { childList: true, subtree: true, characterData: true });
      state = window.__antigravityAutoClick = {
        key,
        scan,
        clicks,
        alive: Date.now(),
        stop() { observer.disconnect(); clearTimeout(pending); },
      };
    }
    state.alive = Date.now();
    state.scan();
    return state.clicks.splice(0);
  })()`;
}

const REMOVE_PAGE_SCRIPT = '(() => { if (window.__antigravityAutoClick) window.__antigravityAutoClick.stop(); delete window.__antigravityAutoClick; })()';

class DevToolsSession {
  static connect(url) {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(url);
      const timer = setTimeout(() => {
        socket.close();
        reject(new Error('timed out'));
      }, 4000);
      socket.onopen = () => {
        clearTimeout(timer);
        resolve(new DevToolsSession(socket));
      };
      socket.onerror = () => {
        clearTimeout(timer);
        reject(new Error('connection failed'));
      };
    });
  }

  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    this.closed = false;
    socket.onmessage = (event) => this.receive(event.data);
    socket.onclose = () => this.fail(new Error('closed'));
    socket.onerror = () => this.fail(new Error('socket error'));
  }

  receive(data) {
    let message;
    try {
      message = JSON.parse(data);
    } catch {
      return;
    }
    const request = this.pending.get(message.id);
    if (!request) return;
    this.pending.delete(message.id);
    clearTimeout(request.timer);
    if (message.error) request.reject(new Error(message.error.message));
    else request.resolve(message.result);
  }

  fail(error) {
    this.closed = true;
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(error);
    }
    this.pending.clear();
  }

  send(method, params, timeout = 5000) {
    if (this.closed) return Promise.reject(new Error('closed'));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  async evaluate(expression) {
    const response = await this.send('Runtime.evaluate', { expression, returnByValue: true, silent: true });
    return response.result && response.result.value;
  }

  close() {
    this.closed = true;
    this.socket.close();
  }
}

class AutoAccept {
  constructor(context) {
    this.output = vscode.window.createOutputChannel('Auto Click');
    this.statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    this.statusItem.command = 'autoClick.toggle';
    this.sessions = new Map();
    this.clicks = 0;
    this.portReachable = undefined;
    this.portWarningShown = false;
    this.disposed = false;
    this.ticking = false;
    this.timer = undefined;

    context.subscriptions.push(
      this.output,
      this.statusItem,
      vscode.commands.registerCommand('autoClick.toggle', () => this.setEnabled(!this.enabled)),
      vscode.commands.registerCommand('autoClick.showLog', () => this.output.show()),
      vscode.window.registerUriHandler({ handleUri: (uri) => this.handleUri(uri) }),
      vscode.workspace.onDidChangeConfiguration((event) => {
        if (event.affectsConfiguration('autoClick')) this.applySettings();
      }),
    );
  }

  get config() {
    return vscode.workspace.getConfiguration('autoClick');
  }

  get enabled() {
    return this.config.get('enabled', true);
  }

  start() {
    this.port = this.config.get('debugPort', 9333);
    try {
      this.argvFile = argvFile();
      this.port = argv.readDebugPort(this.argvFile) || this.port;
      if (argv.enableDebugPort(this.argvFile, this.port)) this.askForRestart();
    } catch (error) {
      this.log(`Could not read or update argv.json: ${error.message}`);
    }
    this.applySettings();
    this.statusItem.show();
  }

  askForRestart() {
    this.portWarningShown = true;
    this.log(`Added "remote-debugging-port": "${this.port}" to ${this.argvFile}`);
    vscode.window
      .showInformationMessage('Auto Click is installed. Quit Antigravity and open it again once to start auto-accepting.', 'Quit Antigravity')
      .then((choice) => {
        if (choice) vscode.commands.executeCommand('workbench.action.quit');
      });
  }

  applySettings() {
    this.pageScript = buildPageScript(this.config.get('buttons', ['Accept all']));
    if (this.enabled) {
      this.schedule(0);
    } else {
      this.stop();
    }
    this.updateStatus();
  }

  async setEnabled(value) {
    await this.config.update('enabled', value, vscode.ConfigurationTarget.Global);
    vscode.window.showInformationMessage(
      value ? 'Auto Click is ON. "Accept all" will be clicked automatically.' : 'Auto Click is OFF.',
    );
  }

  handleUri(uri) {
    const action = uri.path.replace(/^\/+/, '').toLowerCase();
    if (action === 'on') return this.setEnabled(true);
    if (action === 'off') return this.setEnabled(false);
    return this.setEnabled(!this.enabled);
  }

  schedule(delay = POLL_INTERVAL) {
    clearTimeout(this.timer);
    if (!this.disposed && this.enabled) this.timer = setTimeout(() => this.tick(), delay);
  }

  async tick() {
    if (this.ticking) return;
    this.ticking = true;
    try {
      await this.visitPages();
    } catch (error) {
      this.log(`Unexpected error: ${error.message}`);
    } finally {
      this.ticking = false;
      this.schedule();
    }
  }

  async visitPages() {
    const pages = await this.listPages();
    this.setPortReachable(pages !== null);
    if (!pages) {
      this.closeSessions();
      return;
    }
    const liveIds = new Set(pages.map((page) => page.id));
    for (const [id, session] of this.sessions) {
      if (!liveIds.has(id) || session.closed) {
        session.close();
        this.sessions.delete(id);
      }
    }
    for (const page of pages) await this.visit(page);
  }

  async listPages() {
    try {
      const response = await fetch(`http://127.0.0.1:${this.port}/json/list`, { signal: AbortSignal.timeout(2000) });
      const targets = await response.json();
      return targets.filter(
        (target) => target.type === 'page' && target.webSocketDebuggerUrl && String(target.url).startsWith('vscode-file://'),
      );
    } catch {
      return null;
    }
  }

  async visit(page) {
    let session = this.sessions.get(page.id);
    try {
      if (!session) {
        session = await DevToolsSession.connect(page.webSocketDebuggerUrl);
        this.sessions.set(page.id, session);
      }
      if (!this.enabled) return;
      const clicked = await session.evaluate(this.pageScript);
      for (const label of clicked || []) this.recordClick(label, page.title);
    } catch {
      if (session) session.close();
      this.sessions.delete(page.id);
    }
  }

  recordClick(label, title) {
    this.clicks++;
    this.log(`Clicked "${label}" in ${title}`);
    this.updateStatus();
  }

  setPortReachable(reachable) {
    if (reachable === this.portReachable) return;
    this.portReachable = reachable;
    this.log(reachable ? `Connected to Antigravity on port ${this.port}.` : `Port ${this.port} is not open.`);
    this.updateStatus();
    if (!reachable && !this.portWarningShown) {
      this.portWarningShown = true;
      vscode.window
        .showWarningMessage('Auto Click cannot connect yet. Quit Antigravity and open it again once to finish setup.', 'Quit Antigravity')
        .then((choice) => {
          if (choice) vscode.commands.executeCommand('workbench.action.quit');
        });
    }
  }

  updateStatus() {
    const item = this.statusItem;
    item.backgroundColor = undefined;
    if (!this.enabled) {
      item.text = '$(circle-slash) Auto Click';
      item.tooltip = 'Auto Click is OFF. Click to turn it on.';
    } else if (this.portReachable === false) {
      item.text = '$(warning) Auto Click';
      item.tooltip = 'Auto Click is ON but cannot reach Antigravity yet. Quit Antigravity and open it again once.';
      item.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
    } else {
      const times = this.clicks === 1 ? 'time' : 'times';
      item.text = '$(check) Auto Click';
      item.tooltip = `Auto Click is ON. Clicked ${this.clicks} ${times} since Antigravity started. Click to turn it off.`;
    }
  }

  closeSessions() {
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }

  async stop() {
    clearTimeout(this.timer);
    const sessions = [...this.sessions.values()];
    this.sessions.clear();
    await Promise.allSettled(sessions.map((session) => session.evaluate(REMOVE_PAGE_SCRIPT)));
    for (const session of sessions) session.close();
  }

  async dispose() {
    this.disposed = true;
    await this.stop();
  }

  log(message) {
    this.output.appendLine(`[${new Date().toLocaleTimeString()}] ${message}`);
  }
}

let autoAccept;

function activate(context) {
  autoAccept = new AutoAccept(context);
  autoAccept.start();
}

function deactivate() {
  return autoAccept && autoAccept.dispose();
}

module.exports = { activate, deactivate };
