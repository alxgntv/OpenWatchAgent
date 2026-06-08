# Locked Phone Flow

OpenWatch uses an async iPhone relay flow for Watch voice requests when the iPhone can be locked and the iPhone app can be in the background.

## Flow

1. The Watch records `audio.m4a`.
2. The Watch sends the file to the iPhone with `WCSession.transferFile`.
3. The iPhone receives the file and submits it to the backend.
4. The backend accepts the audio job and returns a `serverJobId`.
5. The iPhone sends the Watch a `jobUpdated` message with `status=running`, `statusDetail=Processing...`, and `gatewayRunId=serverJobId`.
6. The Watch stores the active job and polls the iPhone every 5 seconds for up to 120 seconds.
7. Each Watch poll uses `requestSync`; the iPhone performs a short backend status check instead of keeping one long WSS open.
8. If the backend is still processing, the iPhone keeps the job in `Processing...`.
9. If the backend is done, the iPhone sends `status=done` with the final reply to the Watch.
10. The Watch displays the reply to the user.

## Rule

The iPhone does not hold a long-lived WSS connection while waiting for the agent reply. It only creates the backend job, returns the accepted job id to the Watch, and answers short status polls from the Watch.

## Status Mapping

- `jobId`: local Watch job id.
- `gatewayRunId`: backend `serverJobId`.
- `sending`: audio file is being handed off to the iPhone/backend.
- `running` + `Processing...`: backend accepted the job and is still working.
- `done`: final reply is available and shown on Watch.
- `failed`: submit or backend status check failed.
