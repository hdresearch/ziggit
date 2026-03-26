// browser/ziggit.js — In-memory filesystem + WASM loader for ziggit
// Provides a complete git-in-the-browser experience via ziggit's WASM build.

class ZiggitBrowser {
  constructor(corsProxy) {
    this.corsProxy = corsProxy || "";
    this.fs = new Map();      // path → Uint8Array
    this.dirs = new Set();    // known directories
    this.instance = null;
    this.memory = null;
    this._ready = false;
  }

  async load(wasmUrl) {
    const imports = { env: this._makeHostFunctions() };
    const response = await fetch(wasmUrl);
    const { instance } = await WebAssembly.instantiateStreaming(response, imports);
    this.instance = instance;
    this.memory = instance.exports.memory;
    this._ready = true;
  }

  _makeHostFunctions() {
    const self = this;
    return {
      host_write_file: (pathPtr, pathLen, dataPtr, dataLen) => {
        const path = self._readStr(pathPtr, pathLen);
        const data = new Uint8Array(self.memory.buffer, dataPtr, dataLen).slice();
        self.fs.set(path, data);
        // Auto-create parent directories
        const parts = path.split('/');
        for (let i = 1; i < parts.length; i++) {
          self.dirs.add(parts.slice(0, i).join('/'));
        }
        return 1;
      },
      host_read_file: (pathPtr, pathLen, outPtrPtr, outLenPtr) => {
        const path = self._readStr(pathPtr, pathLen);
        const data = self.fs.get(path);
        if (!data) return 0;
        const ptr = self.instance.exports.ziggit_alloc(data.length);
        if (ptr === 0) return 0;
        new Uint8Array(self.memory.buffer, ptr, data.length).set(data);
        new DataView(self.memory.buffer).setUint32(outPtrPtr, ptr, true);
        new DataView(self.memory.buffer).setUint32(outLenPtr, data.length, true);
        return 1;
      },
      host_file_exists: (pathPtr, pathLen) => {
        const path = self._readStr(pathPtr, pathLen);
        return (self.fs.has(path) || self.dirs.has(path)) ? 1 : 0;
      },
      host_make_dir: (pathPtr, pathLen) => {
        self.dirs.add(self._readStr(pathPtr, pathLen));
        return 1;
      },
      host_delete_file: (pathPtr, pathLen) => {
        self.fs.delete(self._readStr(pathPtr, pathLen));
        return 1;
      },
      host_get_cwd: (dataPtrPtr, dataLenPtr) => {
        const cwd = "/";
        const enc = new TextEncoder().encode(cwd);
        const ptr = self.instance.exports.ziggit_alloc(enc.length);
        if (ptr === 0) return 0;
        new Uint8Array(self.memory.buffer, ptr, enc.length).set(enc);
        new DataView(self.memory.buffer).setUint32(dataPtrPtr, ptr, true);
        new DataView(self.memory.buffer).setUint32(dataLenPtr, enc.length, true);
        return 1;
      },
      host_write_stdout: (ptr, len) => {
        console.log("[ziggit]", self._readStr(ptr, len));
      },
      host_write_stderr: (ptr, len) => {
        console.error("[ziggit]", self._readStr(ptr, len));
      },
      host_http_get: (urlPtr, urlLen, respPtrPtr, respLenPtr) => {
        const rawUrl = self._readStr(urlPtr, urlLen);
        const url = self.corsProxy ? self.corsProxy + rawUrl : rawUrl;
        const xhr = new XMLHttpRequest();
        xhr.open('GET', url, false); // synchronous — required for WASM host functions
        xhr.responseType = 'arraybuffer';
        try { xhr.send(); } catch (e) { console.error("HTTP GET failed:", e); return -1; }
        if (xhr.status < 200 || xhr.status >= 300) return -1;
        const data = new Uint8Array(xhr.response);
        const ptr = self.instance.exports.ziggit_alloc(data.length);
        if (ptr === 0) return -2;
        new Uint8Array(self.memory.buffer, ptr, data.length).set(data);
        new DataView(self.memory.buffer).setUint32(respPtrPtr, ptr, true);
        new DataView(self.memory.buffer).setUint32(respLenPtr, data.length, true);
        return 0;
      },
      host_http_post: (urlPtr, urlLen, bodyPtr, bodyLen, ctPtr, ctLen, respPtrPtr, respLenPtr) => {
        const rawUrl = self._readStr(urlPtr, urlLen);
        const url = self.corsProxy ? self.corsProxy + rawUrl : rawUrl;
        const body = new Uint8Array(self.memory.buffer, bodyPtr, bodyLen).slice();
        const contentType = self._readStr(ctPtr, ctLen);
        const xhr = new XMLHttpRequest();
        xhr.open('POST', url, false); // synchronous
        xhr.setRequestHeader('Content-Type', contentType);
        xhr.responseType = 'arraybuffer';
        try { xhr.send(body); } catch (e) { console.error("HTTP POST failed:", e); return -1; }
        if (xhr.status < 200 || xhr.status >= 300) return -1;
        const data = new Uint8Array(xhr.response);
        const ptr = self.instance.exports.ziggit_alloc(data.length);
        if (ptr === 0) return -2;
        new Uint8Array(self.memory.buffer, ptr, data.length).set(data);
        new DataView(self.memory.buffer).setUint32(respPtrPtr, ptr, true);
        new DataView(self.memory.buffer).setUint32(respLenPtr, data.length, true);
        return 0;
      },
    };
  }

  // ========== String helpers ==========

  _readStr(ptr, len) {
    return new TextDecoder().decode(new Uint8Array(this.memory.buffer, ptr, len));
  }

  _writeStr(str) {
    const encoded = new TextEncoder().encode(str);
    const ptr = this.instance.exports.ziggit_alloc(encoded.length);
    new Uint8Array(this.memory.buffer, ptr, encoded.length).set(encoded);
    return { ptr, len: encoded.length };
  }

  _readOutput(ptr, len) {
    const str = this._readStr(ptr, len);
    this.instance.exports.ziggit_free(ptr, len);
    return str;
  }

  // ========== High-level API ==========

  /** Get ziggit version string */
  version() {
    const outPtr = this.instance.exports.ziggit_alloc(128);
    const len = this.instance.exports.ziggit_version(outPtr, 128);
    return this._readStr(outPtr, len);
  }

  /** Initialize a new repo at path */
  init(path) {
    const p = this._writeStr(path);
    return this.instance.exports.ziggit_init(p.ptr, p.len);
  }

  /** Check if path is a git repo */
  isRepo(path) {
    const p = this._writeStr(path);
    return this.instance.exports.ziggit_is_repo(p.ptr, p.len) === 1;
  }

  /** Clone a bare repository. Returns 0 on success. */
  cloneBare(url, target) {
    const u = this._writeStr(url);
    const t = this._writeStr(target);
    return this.instance.exports.ziggit_clone_bare(u.ptr, u.len, t.ptr, t.len);
  }

  /** Index the pack file after clone (required before reading objects) */
  indexPack(path) {
    const p = this._writeStr(path);
    return this.instance.exports.ziggit_index_pack(p.ptr, p.len);
  }

  /** Get HEAD commit hash (40 hex chars) */
  getHead(path) {
    const p = this._writeStr(path);
    const outPtr = this.instance.exports.ziggit_alloc(40);
    const rc = this.instance.exports.ziggit_rev_parse_head(p.ptr, p.len, outPtr);
    if (rc !== 0) return null;
    return this._readStr(outPtr, 40);
  }

  /** Get current branch name */
  getBranch(path) {
    const p = this._writeStr(path);
    const outPtr = this.instance.exports.ziggit_alloc(256);
    const len = this.instance.exports.ziggit_current_branch(p.ptr, p.len, outPtr, 256);
    if (len <= 0) return null;
    return this._readStr(outPtr, len);
  }

  /** List remote refs. Returns array of {hash, ref} */
  lsRemote(url) {
    const u = this._writeStr(url);
    const outPtr = this.instance.exports.ziggit_alloc(65536);
    const len = this.instance.exports.ziggit_ls_remote(u.ptr, u.len, outPtr, 65536);
    if (len <= 0) return [];
    const text = this._readStr(outPtr, len);
    return text.trim().split('\n').map(line => {
      const [hash, ref] = line.split(' ');
      return { hash, ref };
    });
  }

  /** Read a git object by hash. Returns {type, data} or null */
  readObject(hash) {
    const h = this._writeStr(hash);
    const outPtr = this.instance.exports.ziggit_alloc(1048576); // 1MB buffer
    const typePtr = this.instance.exports.ziggit_alloc(4);
    const len = this.instance.exports.ziggit_read_object(h.ptr, h.len, outPtr, 1048576, typePtr);
    if (len < 0) return null;
    const typeVal = new DataView(this.memory.buffer).getUint32(typePtr, true);
    const typeNames = { 1: 'commit', 2: 'tree', 3: 'blob', 4: 'tag' };
    const data = new Uint8Array(this.memory.buffer, outPtr, len).slice();
    return { type: typeNames[typeVal] || 'unknown', data, text: new TextDecoder().decode(data) };
  }

  /** Get commit log. Returns array of {hash, message, author, parent} */
  getLog(path, maxCount = 20) {
    const p = this._writeStr(path);
    const outPtr = this.instance.exports.ziggit_alloc(262144); // 256KB
    const len = this.instance.exports.ziggit_log(p.ptr, p.len, maxCount, outPtr, 262144);
    if (len <= 0) return [];
    const json = this._readStr(outPtr, len);
    try { return JSON.parse(json); } catch { return []; }
  }

  /** List tree entries. Returns array of {mode, name, hash, type} */
  lsTree(treeHash) {
    const h = this._writeStr(treeHash);
    const outPtr = this.instance.exports.ziggit_alloc(262144);
    const len = this.instance.exports.ziggit_ls_tree(h.ptr, h.len, outPtr, 262144);
    if (len <= 0) return [];
    const json = this._readStr(outPtr, len);
    try { return JSON.parse(json); } catch { return []; }
  }

  /** Read a file from a commit. Returns string content or null */
  readFile(commitHash, filePath) {
    const c = this._writeStr(commitHash);
    const f = this._writeStr(filePath);
    const outPtr = this.instance.exports.ziggit_alloc(1048576); // 1MB
    const len = this.instance.exports.ziggit_read_file(c.ptr, c.len, f.ptr, f.len, outPtr, 1048576);
    if (len < 0) return null;
    return this._readStr(outPtr, len);
  }

  /** Get the tree hash for a commit */
  commitTree(commitHash) {
    const c = this._writeStr(commitHash);
    const outPtr = this.instance.exports.ziggit_alloc(40);
    const rc = this.instance.exports.ziggit_commit_tree(c.ptr, c.len, outPtr);
    if (rc !== 0) return null;
    return this._readStr(outPtr, 40);
  }

  /** Hash a blob without storing it */
  hashBlob(data) {
    const d = this._writeStr(data);
    const outPtr = this.instance.exports.ziggit_alloc(40);
    const rc = this.instance.exports.ziggit_hash_blob(d.ptr, d.len, outPtr);
    if (rc !== 0) return null;
    return this._readStr(outPtr, 40);
  }

  /** Debug: list all files in in-memory FS */
  debugFs() {
    const files = [];
    for (const [path, data] of this.fs) {
      files.push({ path, size: data.length });
    }
    return files.sort((a, b) => a.path.localeCompare(b.path));
  }
}
