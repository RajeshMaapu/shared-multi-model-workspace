# Workshop-owned shared UI policy — approved design, not installed

For every UI design or change, first build the intended behavior as a web app. Use the computer-use skill to compare it against the approved visuals and exercise its intended interactions. Save the reference, rendered evidence, findings and retest result in the task. Carry the UI into the final macOS Electron app only after that web validation passes. If computer-use validation is blocked, report the blocker and do not claim UI validation or proceed with the carry-over.

Scope: Workshop work only. This user-approved shared rule is an explicit exception to excluding unrelated custom instructions. It does not authorize loading personal/repository agent instructions or override native capability/permission requirements.

Future integration point: versioned Workshop shared turn policy in `Sources/WorkshopService/Adapter.swift`, delivered to all general engineers and the proposed Astra operator. Runtime edit and enforcement are deferred under the latest design-only scope. A later service transition gate should bind validation evidence to the exact web revision before allowing Electron integration.
