//! Shared shortcut spelling normalization for the editor source plugins.
#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub(crate) struct Key {
    pub(crate) key: String,
    pub(crate) modifiers: Vec<&'static str>,
}

pub(crate) fn keypress(input: &str) -> Option<Key> {
    let value = input.to_ascii_lowercase();
    let parts: Vec<_> = value.split('+').collect();
    let last = *parts.last()?;
    if last.is_empty() || last == "delete" {
        return None;
    }
    let mut present = [false; 4];
    for part in &parts[..parts.len() - 1] {
        let index = match *part {
            "ctrl" | "control" => 0,
            "alt" | "option" => 1,
            "shift" => 2,
            "cmd" | "meta" | "command" => 3,
            _ => return None,
        };
        if present[index] {
            return None;
        }
        present[index] = true;
    }
    let name = match last {
        "enter" => "return",
        "backspace" => "backspace",
        "escape" | "esc" => return None,
        other => other,
    };
    let function = name
        .strip_prefix('f')
        .and_then(|n| n.parse::<u8>().ok())
        .is_some_and(|n| (1..=20).contains(&n) && name == format!("f{n}"));
    let printable = name.len() == 1 && name.as_bytes()[0].is_ascii_graphic();
    if !function
        && !printable
        && ![
            "up",
            "down",
            "left",
            "right",
            "return",
            "tab",
            "space",
            "backspace",
        ]
        .contains(&name)
    {
        return None;
    }
    if (printable || name == "space") && !(present[0] || present[1] || present[3]) {
        return None;
    }
    let modifiers = ["control", "alt", "shift", "meta"]
        .into_iter()
        .enumerate()
        .filter_map(|(index, modifier)| present[index].then_some(modifier))
        .collect();
    Some(Key {
        key: name.to_string(),
        modifiers,
    })
}

pub(crate) fn idea_keypress(input: &str) -> Option<Key> {
    let mut parts: Vec<_> = input
        .split_whitespace()
        .map(str::to_ascii_lowercase)
        .collect();
    let key = parts.last_mut()?;
    *key = match key.as_str() {
        "open_bracket" => "[",
        "close_bracket" => "]",
        "back_slash" => "\\",
        "back_space" => "backspace",
        "comma" => ",",
        "period" => ".",
        "slash" => "/",
        "minus" => "-",
        "equals" => "=",
        other => other,
    }
    .to_string();
    keypress(&parts.join("+"))
}
