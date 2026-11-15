//// Deployment recording for runner updates. The transformation is pure so
//// tests can simulate an apply result without a display or a live app.

import campy_broker/state_store

pub fn applied(
  state: state_store.BrokerState,
  app: String,
  version: Int,
) -> state_store.BrokerState {
  state_store.record_report(state, app, version, state_store.Applied)
}

pub fn failed(
  state: state_store.BrokerState,
  app: String,
  version: Int,
  detail: String,
) -> state_store.BrokerState {
  state_store.record_report(
    state,
    app,
    version,
    state_store.ReportedFailed(detail),
  )
}
