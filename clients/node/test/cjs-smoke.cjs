"use strict";

const assert = require("node:assert/strict");
const sdk = require("../dist/cjs/index.js");

assert.equal(typeof sdk.Tay, "function");
assert.equal(typeof sdk.TayHTTP, "function");
assert.equal(typeof sdk.TayHTTPWorker, "function");
