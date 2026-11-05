//! Bounded recovery of disassembly windows (`debug.planDisassemblyWindow`,
//! `debug.reduceDisassemblyPage`).
//!
//! The disassembly view lists instructions around the selected frame's
//! instruction pointer and extends the listing at either edge as the user
//! scrolls. Adapters may refuse a window that crosses an unmapped address or a
//! negative `instructionOffset` instead of returning a short page, and some
//! repeat the edge forever at a boundary. Core owns the bounded request
//! sequence that recovers from those replies: retry the first window forward,
//! halve a refused page, and probe the known edge before declaring a direction
//! exhausted. Hosts own the transport, the rendered rows, the viewport and the
//! scroll anchor.
//!
//! Addresses are opaque adapter strings. Core only compares two spellings of
//! the same address and never does arithmetic on them or guesses an
//! instruction length.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// Largest window a host may request in one `disassemble` call.
const MAX_INSTRUCTION_COUNT: u32 = 4_096;
/// Upper bound of instructions accepted in one reply and of known edge addresses.
const MAX_REDUCED_ITEMS: usize = 8_192;
const MAX_ADDRESS_BYTES: usize = 128;
const MAX_MESSAGE_BYTES: usize = 4_096;

/// Which part of the listing a fetch extends.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum DisassemblyDirection {
    /// The first window around the instruction pointer.
    Around,
    /// Instructions above the first listed one.
    Before,
    /// Instructions below the last listed one.
    After,
}

/// Where a fetch is in its bounded request sequence.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum DisassemblyFetchPhase {
    /// Requesting a window of `count` instructions.
    Window,
    /// The first window was refused with a negative offset; retry it from the
    /// instruction pointer itself.
    RetryForward,
    /// Even one neighbouring instruction was refused; check that the known
    /// edge still disassembles before declaring the direction exhausted.
    EdgeProbe,
}

/// One DAP `disassemble` request the host sends as is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DisassembleRequestArguments {
    pub(crate) memory_reference: String,
    pub(crate) instruction_offset: i64,
    pub(crate) instruction_count: u32,
}

/// The cursor of one fetch, owned by Core and echoed by the host with each reply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DisassemblyFetch {
    pub(crate) direction: DisassemblyDirection,
    /// The instruction pointer (`around`) or the listed edge (`before`, `after`).
    pub(crate) reference: String,
    pub(crate) phase: DisassemblyFetchPhase,
    /// Instructions requested by the current window.
    pub(crate) count: u32,
    /// Instructions listed before the anchor by the first window.
    #[serde(default)]
    pub(crate) instructions_before: u32,
    /// The adapter's diagnostic for the refused window an edge probe follows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) window_failure: Option<String>,
    pub(crate) request: DisassembleRequestArguments,
}

/// Input of `debug.planDisassemblyWindow`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct PlanDisassemblyWindowRequest {
    pub(crate) direction: DisassemblyDirection,
    pub(crate) reference: String,
    pub(crate) count: u32,
    /// Only for `around`: how many of `count` lie before the anchor.
    #[serde(default)]
    pub(crate) instructions_before: u32,
}

/// The identity of one returned instruction, as the adapter spelled it.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DisassemblyReplyInstruction {
    pub(crate) address: String,
    #[serde(default)]
    pub(crate) instruction: String,
    #[serde(default)]
    pub(crate) instruction_bytes: Option<String>,
}

/// What the adapter answered to `fetch.request`.
#[derive(Debug, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub(crate) enum DisassemblyReply {
    Instructions {
        instructions: Vec<DisassemblyReplyInstruction>,
    },
    /// The adapter answered the request with `success: false`.
    Rejected { message: String },
    /// Transport failure, timeout or cancellation; never mistaken for a boundary.
    Failed { message: String },
}

/// Input of `debug.reduceDisassemblyPage`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ReduceDisassemblyPageRequest {
    pub(crate) fetch: DisassemblyFetch,
    pub(crate) reply: DisassemblyReply,
    /// Addresses already listed on the side being extended; the page drops them.
    #[serde(default)]
    pub(crate) known_addresses: Vec<String>,
}

/// Output of `debug.reduceDisassemblyPage`.
#[derive(Debug, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub(crate) enum DisassemblyStep {
    /// Send `fetch.request` next and reduce its reply with this fetch.
    Request { fetch: DisassemblyFetch },
    /// The fetch finished. `keep` indexes the reply's instructions to list, in
    /// order; `exhausted` means this direction has nothing more to list.
    Page { keep: Vec<usize>, exhausted: bool },
    /// The fetch failed; show the adapter's own message.
    Failed { message: String },
}

/// Plans the first request of a fetch.
pub(crate) fn plan_disassembly_window(
    request: PlanDisassemblyWindowRequest,
) -> Result<DisassemblyFetch, CoreError> {
    validate_address(&request.reference)?;
    validate_count(request.count)?;
    if request.direction != DisassemblyDirection::Around && request.instructions_before != 0 {
        return Err(invalid(
            "instructionsBefore applies only to the first window.",
        ));
    }
    if request.instructions_before > request.count {
        return Err(invalid("instructionsBefore exceeds the window."));
    }
    let mut fetch = DisassemblyFetch {
        direction: request.direction,
        reference: request.reference,
        phase: DisassemblyFetchPhase::Window,
        count: request.count,
        instructions_before: request.instructions_before,
        window_failure: None,
        request: DisassembleRequestArguments {
            memory_reference: String::new(),
            instruction_offset: 0,
            instruction_count: 0,
        },
    };
    fetch.request = arguments(&fetch);
    Ok(fetch)
}

/// Reduces one adapter reply to the next step of the fetch.
pub(crate) fn reduce_disassembly_page(
    request: ReduceDisassemblyPageRequest,
) -> Result<DisassemblyStep, CoreError> {
    let ReduceDisassemblyPageRequest {
        mut fetch,
        reply,
        known_addresses,
    } = request;
    validate_address(&fetch.reference)?;
    validate_count(fetch.count)?;
    if fetch.request != arguments(&fetch) {
        return Err(invalid("The disassembly fetch does not match its request."));
    }
    if known_addresses.len() > MAX_REDUCED_ITEMS {
        return Err(invalid("Too many known disassembly addresses."));
    }
    match reply {
        DisassemblyReply::Instructions { instructions } => {
            if instructions.len() > MAX_REDUCED_ITEMS {
                return Err(invalid("Too many disassembled instructions."));
            }
            let listed = addressable(&instructions);
            match (fetch.direction, fetch.phase) {
                (_, DisassemblyFetchPhase::EdgeProbe) => {
                    let edge = canonical_address(&fetch.reference);
                    if listed
                        .iter()
                        .any(|&index| canonical_address(&instructions[index].address) == edge)
                    {
                        Ok(DisassemblyStep::Page {
                            keep: Vec::new(),
                            exhausted: true,
                        })
                    } else {
                        Ok(failed(fetch.window_failure.unwrap_or_default()))
                    }
                }
                (DisassemblyDirection::Around, _) => Ok(DisassemblyStep::Page {
                    keep: listed,
                    exhausted: false,
                }),
                _ => {
                    let mut seen: BTreeSet<String> = known_addresses
                        .iter()
                        .map(|address| canonical_address(address))
                        .collect();
                    // Some adapters repeat the edge forever at an unmapped boundary.
                    let keep: Vec<usize> = listed
                        .into_iter()
                        .filter(|&index| {
                            seen.insert(canonical_address(&instructions[index].address))
                        })
                        .collect();
                    let exhausted = keep.is_empty();
                    Ok(DisassemblyStep::Page { keep, exhausted })
                }
            }
        }
        // An adapter may refuse a negative `instructionOffset` in any way; the
        // first window then starts at the instruction pointer instead of failing
        // the whole view.
        DisassemblyReply::Rejected { .. } | DisassemblyReply::Failed { .. }
            if fetch.direction == DisassemblyDirection::Around
                && fetch.phase == DisassemblyFetchPhase::Window
                && fetch.request.instruction_offset < 0 =>
        {
            fetch.phase = DisassemblyFetchPhase::RetryForward;
            fetch.request = arguments(&fetch);
            Ok(DisassemblyStep::Request { fetch })
        }
        // Transport failures, timeouts and cancellation are real errors and are
        // never mistaken for a mapping boundary.
        DisassemblyReply::Failed { message } => Ok(failed(message)),
        DisassemblyReply::Rejected { message } => match (fetch.direction, fetch.phase) {
            (
                DisassemblyDirection::Before | DisassemblyDirection::After,
                DisassemblyFetchPhase::Window,
            ) if fetch.count > 1 => {
                // A page can cross an unmapped boundary while nearer
                // instructions stay readable; ask for a smaller window.
                fetch.count /= 2;
                fetch.request = arguments(&fetch);
                Ok(DisassemblyStep::Request { fetch })
            }
            (
                DisassemblyDirection::Before | DisassemblyDirection::After,
                DisassemblyFetchPhase::Window,
            ) => {
                // Adapters report an unmapped neighbour as a generic failure.
                // Only a still-readable edge proves the boundary.
                fetch.phase = DisassemblyFetchPhase::EdgeProbe;
                fetch.window_failure = Some(bounded_message(message));
                fetch.request = arguments(&fetch);
                Ok(DisassemblyStep::Request { fetch })
            }
            _ => Ok(failed(message)),
        },
    }
}

/// The DAP arguments a fetch's current phase sends.
fn arguments(fetch: &DisassemblyFetch) -> DisassembleRequestArguments {
    let count = i64::from(fetch.count);
    let (instruction_offset, instruction_count) = match (fetch.direction, fetch.phase) {
        (_, DisassemblyFetchPhase::EdgeProbe) => (0, 1),
        (DisassemblyDirection::Around, DisassemblyFetchPhase::Window) => {
            (-i64::from(fetch.instructions_before), fetch.count)
        }
        (DisassemblyDirection::Around, DisassemblyFetchPhase::RetryForward) => (0, fetch.count),
        (DisassemblyDirection::Before, _) => (-count, fetch.count),
        (DisassemblyDirection::After, _) => (1, fetch.count),
    };
    DisassembleRequestArguments {
        memory_reference: fetch.reference.clone(),
        instruction_offset,
        instruction_count,
    }
}

/// Indexes of real instructions. Adapters may pad a short window with empty
/// invalid entries; they are not addressable rows and must not become the
/// next paging anchor.
fn addressable(instructions: &[DisassemblyReplyInstruction]) -> Vec<usize> {
    instructions
        .iter()
        .enumerate()
        .filter(|(_, instruction)| {
            !instruction.instruction.trim().is_empty()
                || instruction
                    .instruction_bytes
                    .as_deref()
                    .is_some_and(|bytes| !bytes.is_empty())
        })
        .map(|(index, _)| index)
        .collect()
}

/// Lowercase, no `0x`, no leading zeros, so `0x0000000100003f50` equals
/// `0x100003f50`. Text only: a 64-bit pointer is never parsed into a number.
pub(crate) fn canonical_address(address: &str) -> String {
    let lowered = address.trim().to_ascii_lowercase();
    let digits = lowered.strip_prefix("0x").unwrap_or(&lowered);
    let significant = digits.trim_start_matches('0');
    if significant.is_empty() {
        "0".to_string()
    } else {
        significant.to_string()
    }
}

fn failed(message: String) -> DisassemblyStep {
    DisassemblyStep::Failed {
        message: bounded_message(message),
    }
}

fn bounded_message(mut message: String) -> String {
    if message.len() > MAX_MESSAGE_BYTES {
        let mut end = MAX_MESSAGE_BYTES;
        while !message.is_char_boundary(end) {
            end -= 1;
        }
        message.truncate(end);
    }
    message
}

fn validate_address(address: &str) -> Result<(), CoreError> {
    if address.trim().is_empty() || address.len() > MAX_ADDRESS_BYTES {
        return Err(invalid(
            "A disassembly reference must be a non-empty address.",
        ));
    }
    Ok(())
}

fn validate_count(count: u32) -> Result<(), CoreError> {
    if count == 0 || count > MAX_INSTRUCTION_COUNT {
        return Err(invalid(
            "The disassembly window must hold 1 to 4096 instructions.",
        ));
    }
    Ok(())
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../../shared/fixtures/debug/disassembly-paging-v1.json"
        ))
        .unwrap()
    }

    // Each scenario replays one bounded request sequence: the requests Core asks
    // for and the step it returns after every adapter reply.
    #[test]
    fn disassembly_paging_matches_the_shared_fixture() {
        let fixture = fixture();
        for scenario in fixture["scenarios"].as_array().unwrap() {
            let name = scenario["name"].as_str().unwrap();
            let mut fetch =
                plan_disassembly_window(serde_json::from_value(scenario["plan"].clone()).unwrap())
                    .unwrap();
            let known: Vec<String> =
                serde_json::from_value(scenario["knownAddresses"].clone()).unwrap_or_default();
            let steps = scenario["steps"].as_array().unwrap();
            for (index, step) in steps.iter().enumerate() {
                assert_eq!(
                    serde_json::to_value(&fetch.request).unwrap(),
                    step["request"],
                    "{name}: step {index} request"
                );
                let result = reduce_disassembly_page(ReduceDisassemblyPageRequest {
                    fetch: fetch.clone(),
                    reply: serde_json::from_value(step["reply"].clone()).unwrap(),
                    known_addresses: known.clone(),
                })
                .unwrap();
                let value = serde_json::to_value(&result).unwrap();
                match result {
                    DisassemblyStep::Request { fetch: next } => {
                        assert_eq!(
                            json!("request"),
                            step["expected"]["kind"],
                            "{name}: step {index}"
                        );
                        fetch = next;
                    }
                    _ => {
                        assert_eq!(value, step["expected"], "{name}: step {index}");
                        assert_eq!(index + 1, steps.len(), "{name}: fetch ended early");
                    }
                }
            }
        }
    }

    #[test]
    fn address_spellings_compare_without_arithmetic() {
        assert_eq!(canonical_address("0x0000000100003F50"), "100003f50");
        assert_eq!(canonical_address("0X0"), "0");
        assert_eq!(canonical_address("0x0000"), "0");
        assert_ne!(
            canonical_address("0xffffffffffffffff"),
            canonical_address("0xfffffffffffffffe")
        );
    }

    #[test]
    fn a_tampered_fetch_is_rejected() {
        let mut fetch = plan_disassembly_window(PlanDisassemblyWindowRequest {
            direction: DisassemblyDirection::After,
            reference: "0x10".into(),
            count: 64,
            instructions_before: 0,
        })
        .unwrap();
        fetch.request.instruction_count = 4_096;
        assert!(reduce_disassembly_page(ReduceDisassemblyPageRequest {
            fetch,
            reply: DisassemblyReply::Failed {
                message: "x".into()
            },
            known_addresses: vec![],
        })
        .is_err());
    }
}
