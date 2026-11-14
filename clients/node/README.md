# Tay Node.js SDK

`tay-client` is the typed Node.js client and worker SDK for Tay Protocol v1.
It supports the same two transports as the Python SDK:

- a local Unix-domain socket for producers and application workers;
- HTTP/JSON for producers and remote workers, with mTLS for non-loopback hosts.

The package has no runtime dependencies and supports maintained Node.js LTS
releases starting with Node 22. It ships both ESM (`import`) and CommonJS
(`require`) entrypoints with TypeScript declarations.

Install it with `npm install tay-client`.

From a Tay checkout:

```sh
npm install ./clients/node
```

## Local producer and worker

```ts
import { Tay } from "tay-client";

const tay = new Tay({ capacity: 4 });

const capture = tay.task("billing.capture.v1", async ({ invoice_id }, signal) => {
  signal.throwIfAborted();
  return { invoice_id, captured: true };
}, { retries: 3, backoff: "exponential" });

await tay.start();

const job = await capture.enqueue(
  { invoice_id: "inv-42" },
  { submission_id: "capture:inv-42" },
);

console.log(await job.waitResult({ timeout: 30 }));
await tay.close();
```

`Tay` follows the same socket discovery order as the Engine and Python SDK:
an explicit `socketPath`, `TAY_SOCKET_PATH`, shared `/run/tay`, XDG runtime,
`TMPDIR`, then the per-user `/tmp/tay-<uid>/tay.sock` fallback.

Use `{ mode: "client" }` for a producer that never executes jobs, or
`{ mode: "worker" }` for a process that only executes registered tasks.
An `AbortSignal` is passed to every handler for cooperative cancellation.

## HTTP producer

```ts
import { TayHTTP } from "tay-client";

const tay = new TayHTTP("http://127.0.0.1:8080");
const job = await tay.enqueue("reports.rebuild.v1", { report_id: "42" });
console.log(await job.status());
```

Remote URLs require HTTPS and client credentials. PEM and PKCS#12 are both
supported by Node's built-in TLS stack:

```ts
const tay = new TayHTTP("https://tay.example:8080", {
  caFile: "/etc/tay/server-ca.pem",
  certFile: "/etc/tay/client.pem",
  keyFile: "/etc/tay/client.key",
});
```

For PKCS#12 use `pfxFile` and, when required, `passphrase`.

## Remote HTTP worker

```ts
import { TayHTTPWorker } from "tay-client";

const worker = new TayHTTPWorker("https://tay.example:8080", {
  caFile: "/etc/tay/server-ca.pem",
  certFile: "/etc/tay/client.pem",
  keyFile: "/etc/tay/client.key",
  capacity: 4,
});

worker.task("reports.rebuild.v1", async ({ report_id }) => ({
  report_id,
  rebuilt: true,
}));

await worker.serve();
```

Worker delivery is at least once. Make external effects idempotent and use the
same stable business identifier as the Tay `submission_id` and the downstream
provider's idempotency key.

## Durable schedules

```ts
await tay.schedule("reports.rebuild.v1", {
  cron: "0 8 * * 1-5",
  timezone: "+02",
  args: { report_id: "42" },
  catchUp: "latest",
  overlap: "skip",
});

await tay.every("cache.warm.v1", {
  minutes: 15,
  delay: 600,
});
```

Use `startAt` for an absolute UTC millisecond timestamp. `delay` and `startAt`
are mutually exclusive. `schedules()`, `getSchedule(id)`, and the returned
handle's `status()` and `cancel()` cover inspection and cancellation.

## Result contract

`job.result()` retrieves an available result and does not wait. Use
`job.waitResult({ timeout, pollInterval, signal })` for bounded polling.
Stored JSON `null` is a successful result. Connection errors and terminal
server errors are not converted into retries or resubmissions.

## License

The Node.js `tay-client` package is MIT licensed. The Tay Engine is distributed
separately under the Elastic License 2.0.
