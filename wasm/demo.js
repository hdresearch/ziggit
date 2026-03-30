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
      const wasmBuf = new Uint8Array(wasmMemory.buffer);
      // Simple: write data at end of memory (not production-safe)
      const offset = wasmMemory.buffer.byteLength - bytes.length - 256;
      wasmBuf.set(bytes, offset);
      new DataView(wasmMemory.buffer).setUint32(dataPtrPtr, offset, true);
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
      const wasmBuf = new Uint8Array(wasmMemory.buffer);
      const offset = wasmMemory.buffer.byteLength - bytes.length - 512;
      wasmBuf.set(bytes, offset);
      new DataView(wasmMemory.buffer).setUint32(dataPtrPtr, offset, true);
      new DataView(wasmMemory.buffer).setUint32(dataLenPtr, bytes.length, true);
      return 1;
    },
    host_read_dir(pathPtr, pathLen, entriesPtrPtr, entriesLenPtr, countPtr) {
      // Minimal stub
      new DataView(wasmMemory.buffer).setUint32(countPtr, 0, true);
      return 1;
    },
    host_http_get(urlPtr, urlLen, respPtrPtr, respLenPtr) {
      // Async HTTP not directly possible from sync WASM – stub for now
      log('[http] GET ' + getStr(urlPtr, urlLen) + ' (not yet implemented)\n');
      return -1;
    },
    host_http_post(urlPtr, urlLen, bodyPtr, bodyLen, respPtrPtr, respLenPtr) {
      log('[http] POST ' + getStr(urlPtr, urlLen) + ' (not yet implemented)\n');
      return -1;
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
    // Write each arg as null-terminated string, build argv array
    const argPtrs = [];
    let offset = wasmMemory.buffer.byteLength - 8192;
    for (const arg of fullArgs) {
      const bytes = encoder.encode(arg + '\0');
      new Uint8Array(wasmMemory.buffer).set(bytes, offset);
      argPtrs.push(offset);
      offset += bytes.length;
    }
    // Write argv pointer array
    const argvBase = offset;
    const dv = new DataView(wasmMemory.buffer);
    for (let i = 0; i < argPtrs.length; i++) {
      dv.setUint32(argvBase + i * 4, argPtrs[i], true);
    }

    const rc = wasmInstance.exports.ziggit_command_line(fullArgs.length, argvBase);
    if (rc !== 0) log('[exit code: ' + rc + ']\n');
  } catch (e) {
    log('[error] ' + e.message + '\n');
    console.error(e);
  }
  log('\n');
}

// Enter key runs command
cmdInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') runCommand(); });

init();
