// ziggit WASM demo – host functions for freestanding platform
const output = document.getElementById('output');
const cmdInput = document.getElementById('cmd');

// In-memory filesystem
const fs = new Map();
let cwd = '/';

// Text encoder/decoder
const encoder = new TextEncoder();
const decoder = new TextDecoder();

// WASM memory helpers
let wasmInstance = null;
let wasmMemory = null;

function getStr(ptr, len) {
  return decoder.decode(new Uint8Array(wasmMemory.buffer, ptr, len));
}

function log(text) {
  output.textContent += text;
  output.scrollTop = output.scrollHeight;
}

// Host functions required by the freestanding platform
const importObject = {
  env: {
    host_write_stdout(ptr, len) {
      log(getStr(ptr, len));
    },
    host_write_stderr(ptr, len) {
      log('[stderr] ' + getStr(ptr, len));
    },
    host_read_file(pathPtr, pathLen, dataPtrPtr, dataLenPtr) {
      const path = getStr(pathPtr, pathLen);
      const data = fs.get(path);
      if (data === undefined) return 0;
      const bytes = typeof data === 'string' ? encoder.encode(data) : data;
      const ptr = wasmInstance.exports.ziggit_alloc(bytes.length);
      if (ptr === 0) return 0;
      // Re-read buffer after alloc (memory may have grown)
      new Uint8Array(wasmMemory.buffer, ptr, bytes.length).set(bytes);
      new DataView(wasmMemory.buffer).setUint32(dataPtrPtr, ptr, true);
      new DataView(wasmMemory.buffer).setUint32(dataLenPtr, bytes.length, true);
      return 1;
    },
    host_write_file(pathPtr, pathLen, dataPtr, dataLen) {
      const path = getStr(pathPtr, pathLen);
      const data = new Uint8Array(wasmMemory.buffer, dataPtr, dataLen).slice();
      fs.set(path, data);
      return 1;
    },
    host_file_exists(pathPtr, pathLen) {
      return fs.has(getStr(pathPtr, pathLen)) ? 1 : 0;
    },
    host_make_dir(pathPtr, pathLen) {
      const path = getStr(pathPtr, pathLen);
      fs.set(path, '__dir__');
      return 1;
    },
    host_delete_file(pathPtr, pathLen) {
      return fs.delete(getStr(pathPtr, pathLen)) ? 1 : 0;
    },
    host_get_cwd(dataPtrPtr, dataLenPtr) {
      const bytes = encoder.encode(cwd);
      const ptr = wasmInstance.exports.ziggit_alloc(bytes.length);
      if (ptr === 0) return 0;
      new Uint8Array(wasmMemory.buffer, ptr, bytes.length).set(bytes);
      new DataView(wasmMemory.buffer).setUint32(dataPtrPtr, ptr, true);
      new DataView(wasmMemory.buffer).setUint32(dataLenPtr, bytes.length, true);
      return 1;
    },
    host_read_dir(pathPtr, pathLen, entriesPtrPtr, entriesLenPtr, countPtr) {
      // Minimal stub
      new DataView(wasmMemory.buffer).setUint32(countPtr, 0, true);
      return 1;
    },
    host_http_get(urlPtr, urlLen, respPtrPtr, respLenPtr) {
      const rawUrl = getStr(urlPtr, urlLen);
      const proxy = window._corsProxy || '';
      const url = proxy ? proxy + encodeURIComponent(rawUrl) : rawUrl;
      log('[http] GET ' + url + '\n');
      const xhr = new XMLHttpRequest();
      xhr.open('GET', url, false);
      xhr.responseType = 'arraybuffer';
      try { xhr.send(); } catch (e) { log('[http] GET error: ' + e.message + '\n'); return -1; }
      if (xhr.status < 200 || xhr.status >= 300) { log('[http] GET status: ' + xhr.status + '\n'); return -1; }
      const data = new Uint8Array(xhr.response);
      const ptr = wasmInstance.exports.ziggit_alloc(data.length);
      if (ptr === 0) return -2;
      new Uint8Array(wasmMemory.buffer, ptr, data.length).set(data);
      new DataView(wasmMemory.buffer).setUint32(respPtrPtr, ptr, true);
      new DataView(wasmMemory.buffer).setUint32(respLenPtr, data.length, true);
      return 0;
    },
    host_http_post(urlPtr, urlLen, bodyPtr, bodyLen, ctPtr, ctLen, respPtrPtr, respLenPtr) {
      const rawUrl = getStr(urlPtr, urlLen);
      const proxy = window._corsProxy || '';
      const url = proxy ? proxy + encodeURIComponent(rawUrl) : rawUrl;
      const body = new Uint8Array(wasmMemory.buffer, bodyPtr, bodyLen).slice();
      const contentType = getStr(ctPtr, ctLen);
      log('[http] POST ' + url + ' (' + body.length + ' bytes)\n');
      const xhr = new XMLHttpRequest();
      xhr.open('POST', url, false);
      xhr.setRequestHeader('Content-Type', contentType);
      xhr.responseType = 'arraybuffer';
      try { xhr.send(body); } catch (e) { log('[http] POST error: ' + e.message + '\n'); return -1; }
      if (xhr.status < 200 || xhr.status >= 300) { log('[http] POST status: ' + xhr.status + '\n'); return -1; }
      const data = new Uint8Array(xhr.response);
      const ptr = wasmInstance.exports.ziggit_alloc(data.length);
      if (ptr === 0) return -2;
      new Uint8Array(wasmMemory.buffer, ptr, data.length).set(data);
      new DataView(wasmMemory.buffer).setUint32(respPtrPtr, ptr, true);
      new DataView(wasmMemory.buffer).setUint32(respLenPtr, data.length, true);
      return 0;
    },
    // Global args access (provided by main_freestanding.zig as exports, but
    // the linker may also look for them as imports in some configurations)
    getGlobalArgc() { return 0; },
    getGlobalArgv() { return 0; },
  },
};

async function init() {
  try {
    const resp = await fetch('ziggit.wasm');
    const bytes = await resp.arrayBuffer();
    const result = await WebAssembly.instantiate(bytes, importObject);
    wasmInstance = result.instance;
    wasmMemory = wasmInstance.exports.memory;
    output.textContent = 'ziggit WASM loaded! Try: --version, --help, init, status\n\n';
  } catch (e) {
    output.textContent = 'Failed to load WASM: ' + e.message + '\n';
    console.error(e);
  }
}

function writeStringToWasm(str) {
  const bytes = encoder.encode(str + '\0');
  const wasmBuf = new Uint8Array(wasmMemory.buffer);
  // Allocate near end of memory
  const base = wasmMemory.buffer.byteLength - 4096;
  wasmBuf.set(bytes, base);
  return base;
}

function runCommand() {
  if (!wasmInstance) { log('WASM not loaded yet\n'); return; }
  const args = cmdInput.value.trim().split(/\s+/);
  const fullArgs = ['ziggit', ...args];

  output.textContent += '$ ziggit ' + args.join(' ') + '\n';

  try {
    // Write each arg as null-terminated string using proper WASM allocation
    const argPtrs = [];
    const allocPtrs = []; // track for cleanup
    for (const arg of fullArgs) {
      const bytes = encoder.encode(arg + '\0');
      const ptr = wasmInstance.exports.ziggit_alloc(bytes.length);
      if (ptr === 0) { log('[error] allocation failed\n'); return; }
      allocPtrs.push({ ptr, len: bytes.length });
      argPtrs.push(ptr);
    }
    // Write all string data after all allocations (buffer is now stable)
    for (let i = 0; i < fullArgs.length; i++) {
      const bytes = encoder.encode(fullArgs[i] + '\0');
      new Uint8Array(wasmMemory.buffer, argPtrs[i], bytes.length).set(bytes);
    }
    // Write argv pointer array
    const argvPtr = wasmInstance.exports.ziggit_alloc(argPtrs.length * 4);
    allocPtrs.push({ ptr: argvPtr, len: argPtrs.length * 4 });
    const dv = new DataView(wasmMemory.buffer);
    for (let i = 0; i < argPtrs.length; i++) {
      dv.setUint32(argvPtr + i * 4, argPtrs[i], true);
    }

    const rc = wasmInstance.exports.ziggit_command_line(fullArgs.length, argvPtr);
    if (rc !== 0) log('[exit code: ' + rc + ']\n');
    // Free allocated memory
    for (const a of allocPtrs) wasmInstance.exports.ziggit_free(a.ptr, a.len);
  } catch (e) {
    log('[error] ' + e.message + '\n');
    console.error(e);
  }
  log('\n');
}

function doClone() {
  if (!wasmInstance) { log('WASM not loaded yet\n'); return; }
  const url = document.getElementById('clone-url').value.trim();
  const proxy = document.getElementById('cors-proxy').value.trim();
  if (!url) { log('Enter a repository URL\n'); return; }

  // For clone, we need to prepend the CORS proxy to HTTP URLs
  // The host_http_get/post functions will be called by WASM with the raw URL
  // We need to make the proxy available to those functions
  window._corsProxy = proxy;

  log('\n== Cloning ' + url + ' ==\n');
  log('CORS proxy: ' + (proxy || '(none)') + '\n');

  try {
    const urlBytes = encoder.encode(url);
    const target = '/repo';
    const targetBytes = encoder.encode(target);

    // Write URL and target to WASM memory (allocate first, write after)
    const urlPtr = wasmInstance.exports.ziggit_alloc(urlBytes.length);
    const targetPtr = wasmInstance.exports.ziggit_alloc(targetBytes.length);
    new Uint8Array(wasmMemory.buffer, urlPtr, urlBytes.length).set(urlBytes);
    new Uint8Array(wasmMemory.buffer, targetPtr, targetBytes.length).set(targetBytes);

    const rc = wasmInstance.exports.ziggit_clone_bare(urlPtr, urlBytes.length, targetPtr, targetBytes.length);
    log('Clone result: ' + rc + '\n');

    if (rc === 0) {
      log('Clone succeeded! Indexing pack...\n');
      const irc = wasmInstance.exports.ziggit_index_pack(targetPtr, targetBytes.length);
      log('Index result: ' + irc + '\n');

      if (irc === 0) {
        // Show version
        const vBuf = wasmInstance.exports.ziggit_alloc(128);
        const vLen = wasmInstance.exports.ziggit_version(vBuf, 128);
        log('Version: ' + getStr(vBuf, vLen) + '\n');

        // Show HEAD
        const headBuf = wasmInstance.exports.ziggit_alloc(40);
        const headRc = wasmInstance.exports.ziggit_rev_parse_head(targetPtr, targetBytes.length, headBuf);
        if (headRc === 0) {
          log('HEAD: ' + getStr(headBuf, 40) + '\n');
        }

        // Show log
        const logBuf = wasmInstance.exports.ziggit_alloc(65536);
        const logLen = wasmInstance.exports.ziggit_log(targetPtr, targetBytes.length, 10, logBuf, 65536);
        if (logLen > 0) {
          const logJson = getStr(logBuf, logLen);
          try {
            const commits = JSON.parse(logJson);
            log('\nCommit log (' + commits.length + ' commits):\n');
            commits.forEach(c => {
              log('  ' + c.hash.slice(0, 8) + ' ' + c.author + ': ' + c.message + '\n');
            });
          } catch(e) { log('Log parse error: ' + e.message + '\n'); }
        }
      }
    }
  } catch (e) {
    log('[error] ' + e.message + '\n');
    console.error(e);
  }
}

// Enter key runs command
cmdInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') runCommand(); });

init();
