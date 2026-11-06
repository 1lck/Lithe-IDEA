//! Editor rules that must run synchronously inside UI state updates.

mod workbench_state;

pub use workbench_state::{
    reduce, reduce_json, Action, EmptyGroups, Group, Reduction, SelectionFallback, State,
    REDUCE_WORKBENCH_STATE,
};
