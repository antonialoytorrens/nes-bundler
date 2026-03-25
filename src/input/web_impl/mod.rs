use std::collections::{HashMap, HashSet};

use wasm_bindgen::JsCast;

use super::buttons::GamepadButton;
use super::gamepad::{GamepadEvent, GamepadState, Gamepads, JoypadGamepadMapping};
use super::{InputId, JoypadState};

pub struct WebGamepadState {
    pressed_buttons: HashSet<GamepadButton>,
    connected: bool,
}

impl WebGamepadState {
    fn new() -> Self {
        Self {
            pressed_buttons: HashSet::new(),
            connected: true,
        }
    }
}

impl GamepadState for WebGamepadState {
    fn is_connected(&self) -> bool {
        self.connected
    }

    fn get_pressed_buttons(&self) -> &HashSet<GamepadButton> {
        &self.pressed_buttons
    }

    fn toggle_button(&mut self, button: &GamepadButton, pressed: bool) {
        if pressed {
            self.pressed_buttons.insert(*button);
        } else {
            self.pressed_buttons.remove(button);
        }
    }
}

pub struct WebGamepads {
    all: HashMap<InputId, Box<dyn GamepadState>>,
}

impl WebGamepads {
    pub fn new() -> Self {
        Self {
            all: HashMap::new(),
        }
    }

    fn get_gamepad(&mut self, id: InputId) -> Option<&mut Box<dyn GamepadState>> {
        self.all.get_mut(&id)
    }

    /// Poll browser Gamepad API and generate events.
    pub fn poll_events(&mut self) -> Vec<GamepadEvent> {
        let mut events = Vec::new();
        let window = match web_sys::window() {
            Some(w) => w,
            None => return events,
        };
        let navigator = window.navigator();
        let gamepads = match navigator.get_gamepads() {
            Ok(g) => g,
            Err(_) => return events,
        };

        for i in 0..gamepads.length() {
            let gp_val = gamepads.get(i);
            if gp_val.is_null() || gp_val.is_undefined() {
                continue;
            }
            let gp: web_sys::Gamepad = match gp_val.dyn_into() {
                Ok(g) => g,
                Err(_) => continue,
            };

            let id: InputId = format!("web-gamepad-{}", gp.index());

            if !self.all.contains_key(&id) {
                self.all
                    .insert(id.clone(), Box::new(WebGamepadState::new()));
                events.push(GamepadEvent::ControllerAdded { which: id.clone() });
            }

            let buttons = gp.buttons();
            let state = self.all.get_mut(&id).unwrap();
            let mapping = web_button_indices();

            for (btn_idx, gamepad_btn) in &mapping {
                let btn_val = buttons.get(*btn_idx as u32);
                let pressed = if !btn_val.is_undefined() && !btn_val.is_null() {
                    let b: web_sys::GamepadButton = btn_val.unchecked_into();
                    b.pressed()
                } else {
                    false
                };

                let was_pressed = state.get_pressed_buttons().contains(gamepad_btn);
                if pressed && !was_pressed {
                    state.toggle_button(gamepad_btn, true);
                    events.push(GamepadEvent::ButtonDown {
                        which: id.clone(),
                        button: *gamepad_btn,
                    });
                } else if !pressed && was_pressed {
                    state.toggle_button(gamepad_btn, false);
                    events.push(GamepadEvent::ButtonUp {
                        which: id.clone(),
                        button: *gamepad_btn,
                    });
                }
            }
        }

        events
    }
}

impl Gamepads for WebGamepads {
    fn get_joypad(&self, id: &InputId, mapping: &JoypadGamepadMapping) -> JoypadState {
        if let Some(state) = self.get_gamepad_by_input_id(id) {
            mapping.calculate_state(state.get_pressed_buttons())
        } else {
            JoypadState(0)
        }
    }

    fn get_gamepad_by_input_id(&self, id: &InputId) -> Option<&dyn GamepadState> {
        self.all.get(id).map(|a| a.as_ref())
    }

    fn advance(&mut self, gamepad_event: &GamepadEvent) {
        match gamepad_event {
            GamepadEvent::ControllerAdded { which } => {
                if !self.all.contains_key(which) {
                    self.all
                        .insert(which.clone(), Box::new(WebGamepadState::new()));
                }
            }
            GamepadEvent::ButtonDown { which, button, .. } => {
                if let Some(state) = self.get_gamepad(which.clone()) {
                    state.toggle_button(button, true);
                }
            }
            GamepadEvent::ButtonUp { which, button, .. } => {
                if let Some(state) = self.get_gamepad(which.clone()) {
                    state.toggle_button(button, false);
                }
            }
        }
    }
}

fn web_button_indices() -> Vec<(usize, GamepadButton)> {
    vec![
        (0, GamepadButton::South),
        (1, GamepadButton::East),
        (2, GamepadButton::West),
        (3, GamepadButton::North),
        (4, GamepadButton::LeftShoulder),
        (5, GamepadButton::RightShoulder),
        (8, GamepadButton::Back),
        (9, GamepadButton::Start),
        (10, GamepadButton::LeftStick),
        (11, GamepadButton::RightStick),
        (12, GamepadButton::DPadUp),
        (13, GamepadButton::DPadDown),
        (14, GamepadButton::DPadLeft),
        (15, GamepadButton::DPadRight),
        (16, GamepadButton::Guide),
    ]
}
