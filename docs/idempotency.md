# Idempotency and external effects

Tay provides durable **at-least-once** job execution. A worker may complete an
external effect and then lose its connection or crash before Tay durably
observes completion. Tay must retry that job rather than silently lose it.
Handlers that charge money, send messages, provision resources, or mutate any
system outside Tay must therefore make repeated execution safe.

## Stable operation identity

Assign every business operation a stable identifier before enqueueing it. Use
the same value as Tay's `submission_id` and as the external system's
idempotency key or merchant reference. Retrying an enqueue after an unknown
connection outcome must reuse both the identifier and the original canonical
job definition.

```python
payment_id = "order-918:capture"

job = await capture_payment.enqueue(
    payment_id,
    "customer-42",
    10_000,
    submission_id=payment_id,
)
```

Represent money in the currency's smallest integral unit rather than binary
floating point. In this example `10_000` means `100.00` for a currency with two
fractional digits.

```python
@tay.task(
    name="billing.capture.v1",
    retries=10,
    backoff="exponential",
)
async def capture_payment(
    payment_id: str,
    customer_id: str,
    amount_minor: int,
):
    return await provider.capture(
        customer_id=customer_id,
        amount_minor=amount_minor,
        idempotency_key=payment_id,
        merchant_reference=payment_id,
    )
```

The payment provider, not the Python return value, is authoritative for the
charge. Tay durably retains the terminal job state, but Protocol v1 retains a
successful result value only in the bounded current listener generation. Store
the business outcome in the authoritative external system or a transactional
business ledger.

## Crash cases

The stable key makes all relevant crash positions safe:

- A crash before the provider call causes a retry that performs the operation.
- A crash after the provider commits but before it replies causes a retry with
  the same key; the provider returns the original operation rather than charging
  again.
- A lost completion acknowledgement causes Tay to retry, but the same provider
  key still identifies the original operation.

Provider lookup by merchant reference is useful for reconciliation:

```python
@tay.task(name="billing.capture.v1", retries=10, backoff="exponential")
async def capture_payment(payment_id: str, customer_id: str, amount_minor: int):
    existing = await provider.find_by_reference(payment_id)
    if existing is not None:
        return normalize(existing)

    return await provider.capture(
        customer_id=customer_id,
        amount_minor=amount_minor,
        idempotency_key=payment_id,
        merchant_reference=payment_id,
    )
```

The preliminary lookup is not itself an exactly-once guarantee: two callers
could both observe absence. The provider must atomically enforce uniqueness of
the idempotency key or merchant reference.

## Local transactional effects

When both the business state and the processed-operation ledger are in one
transactional store, apply them atomically. A unique operation key turns a Tay
retry into a no-op:

```sql
BEGIN;

INSERT INTO processed_operations (operation_id)
VALUES ('order-918:capture')
ON CONFLICT DO NOTHING;

-- Run only when the INSERT added the operation.
UPDATE accounts
SET balance_minor = balance_minor + 10000
WHERE id = 'customer-42';

COMMIT;
```

The insert and business mutation must be in the same transaction. Recording
"done" before or after a non-transactional external call only moves the crash
window; it does not remove it.

## Unsupported exactly-once assumptions

Tay cannot prove whether an arbitrary external side effect occurred. If an API
offers no idempotency key, unique merchant reference, operation lookup, or
transactional integration, there is no way for Tay alone to guarantee both no
loss and no duplicate effect. Disabling retries chooses possible loss instead
of resolving the ambiguity.

For such integrations, use an authorization/capture protocol, a provider that
supports idempotency, or an explicit reconciliation process. Never use a fresh
`submission_id` or provider key when retrying the same business operation.
