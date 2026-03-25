use std::collections::{HashMap, HashSet};

use super::buttons::GamepadButton;
use super::gamepad::{GamepadEvent, GamepadState, Gamepads, JoypadGamepadMapping};
use super::{InputId, JoypadState};

pub struct StubGamepadState {
    pressed_buttons: HashSet<GamepadButton>,
}

impl GamepadState for StubGamepadState {
    fn is_connected(&self) -> bool {
        false
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

pub struct StubGamepads {
    all: HashMap<InputId, Box<dyn GamepadState>>,
}

impl StubGamepads {
    pub fn new() -> Self {
        Self {
            all: HashMap::new(),
        }
    }

    fn get_gamepad(&mut self, id: InputId) -> Option<&mut Box<dyn GamepadState>> {
        self.all.get_mut(&id)
    }
}

impl Gamepads for StubGamepads {
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
                self.all.insert(
                    which.clone(),
                    Box::new(StubGamepadState {
                        pressed_buttons: HashSet::new(),
                    }),
                );
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
