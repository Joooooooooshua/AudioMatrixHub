#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use eframe::egui::{
    self, Align, Button, Color32, ComboBox, CornerRadius, Frame, Layout, Margin, RichText,
    ScrollArea, Slider, Stroke, ViewportBuilder,
};

use audiomatrix_rust_core::{
    AppAudioStream, DspPresetSpeaker, DspPresetTone, SystemAudioController,
};

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: ViewportBuilder::default()
            .with_title("AudioMatrixHub")
            .with_inner_size([376.0, 760.0])
            .with_min_inner_size([340.0, 560.0]),
        ..Default::default()
    };

    eframe::run_native(
        "AudioMatrixHub",
        options,
        Box::new(|cc| {
            configure_dark_theme(&cc.egui_ctx);
            Ok(Box::new(AudioMatrixDesktopApp::new()))
        }),
    )
}

fn configure_dark_theme(ctx: &egui::Context) {
    let mut visuals = egui::Visuals::dark();
    visuals.window_fill = Color32::from_rgb(24, 24, 28);
    visuals.panel_fill = Color32::from_rgb(24, 24, 28);
    visuals.widgets.noninteractive.bg_fill = Color32::from_rgb(35, 35, 42);
    visuals.widgets.inactive.bg_fill = Color32::from_rgb(46, 46, 54);
    visuals.widgets.hovered.bg_fill = Color32::from_rgb(58, 58, 68);
    visuals.widgets.active.bg_fill = Color32::from_rgb(10, 132, 255);
    visuals.selection.bg_fill = Color32::from_rgb(10, 132, 255);
    visuals.selection.stroke = Stroke::new(1.0, Color32::WHITE);
    ctx.set_visuals(visuals);
}

struct AudioMatrixDesktopApp {
    ctrl: SystemAudioController,
    show_tune: bool,
    show_app_mixer: bool,
    show_loopback: bool,
    show_external_chain: bool,
    status_flash: Option<String>,
}

impl AudioMatrixDesktopApp {
    fn new() -> Self {
        Self {
            ctrl: SystemAudioController::new(),
            show_tune: false,
            show_app_mixer: false,
            show_loopback: false,
            show_external_chain: false,
            status_flash: None,
        }
    }

    fn card_frame() -> Frame {
        Frame::new()
            .fill(Color32::from_rgb(35, 35, 42))
            .corner_radius(CornerRadius::same(10))
            .inner_margin(Margin::same(10))
            .stroke(Stroke::new(1.0, Color32::from_rgb(50, 50, 60)))
    }

    fn pill_button(ui: &mut egui::Ui, label: &str, active: bool) -> egui::Response {
        let fill = if active {
            Color32::from_rgb(10, 132, 255)
        } else {
            Color32::from_rgb(48, 48, 56)
        };
        let fg = if active {
            Color32::WHITE
        } else {
            Color32::from_rgb(220, 220, 228)
        };
        ui.add(
            Button::new(RichText::new(label).size(11.0).color(fg))
                .fill(fill)
                .corner_radius(CornerRadius::same(6)),
        )
    }

    fn render_output_section(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.label(
                RichText::new("Output")
                    .size(12.0)
                    .strong()
                    .color(Color32::from_rgb(174, 174, 184)),
            );
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let badge = if self.ctrl.element_host_enabled {
                    "VST3 / AU Host".to_string()
                } else if self.ctrl.dsp_state.is_enabled() {
                    self.ctrl.dsp_state.summary_title()
                } else {
                    self.ctrl.backend_kind.name().to_string()
                };
                ui.label(
                    RichText::new(badge)
                        .size(10.5)
                        .color(Color32::from_rgb(10, 132, 255)),
                );
            });
        });
        ui.add_space(4.0);

        let outputs: Vec<_> = self
            .ctrl
            .devices
            .iter()
            .filter(|d| d.is_output && !d.is_virtual)
            .cloned()
            .collect();

        Self::card_frame().show(ui, |ui| {
            for dev in &outputs {
                let selected = dev.is_default_output;
                ui.horizontal(|ui| {
                    let dot = if selected { "●" } else { "○" };
                    let resp = ui.selectable_label(
                        selected,
                        RichText::new(format!("{}  {} ({})", dot, dev.name, dev.transport))
                            .size(12.0),
                    );
                    if resp.clicked() {
                        self.ctrl.select_output_device(&dev.id);
                    }
                });

                if selected {
                    let mut vol = dev.volume;
                    ui.horizontal(|ui| {
                        ui.add_space(16.0);
                        let changed = ui
                            .add(Slider::new(&mut vol, 0.0..=1.0).show_value(false))
                            .changed();
                        ui.label(
                            RichText::new(format!("{}%", (vol * 100.0).round() as i32)).size(10.5),
                        );
                        if changed {
                            self.ctrl.set_device_volume(&dev.id, vol);
                        }
                    });
                }
            }
        });

        ui.add_space(4.0);
        ui.horizontal(|ui| {
            let mut share = self.ctrl.share_audio_enabled;
            if ui.checkbox(&mut share, "Share Audio (Dual Output)").changed() {
                let sec = self.ctrl.secondary_output_id.clone();
                self.ctrl.set_share_audio(share, sec.as_deref());
            }

            if self.ctrl.share_audio_enabled && outputs.len() > 1 {
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    let mut cur_sec = self.ctrl.secondary_output_id.clone().unwrap_or_default();
                    let cur_label = outputs
                        .iter()
                        .find(|d| d.id == cur_sec)
                        .map(|d| d.name.clone())
                        .unwrap_or_else(|| "Select".to_string());
                    ComboBox::from_id_salt("share_audio_sec")
                        .selected_text(cur_label)
                        .width(120.0)
                        .show_ui(ui, |ui| {
                            for d in outputs.iter().filter(|d| !d.is_default_output) {
                                if ui.selectable_value(&mut cur_sec, d.id.clone(), &d.name).clicked()
                                {
                                    self.ctrl.set_share_audio(true, Some(&cur_sec));
                                }
                            }
                        });
                });
            }
        });

        if self.ctrl.share_audio_enabled {
            let mut sec_vol = self.ctrl.secondary_volume;
            ui.horizontal(|ui| {
                ui.add_space(18.0);
                ui.label(RichText::new("Device B").size(10.5));
                if ui
                    .add(Slider::new(&mut sec_vol, 0.0..=1.0).show_value(false))
                    .changed()
                {
                    self.ctrl.secondary_volume = sec_vol;
                }
                ui.label(
                    RichText::new(format!("{}%", (sec_vol * 100.0).round() as i32)).size(10.5),
                );
            });
        }
    }

    fn render_dsp_section(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.label(
                RichText::new("Built-in Sound")
                    .size(12.0)
                    .strong()
                    .color(Color32::from_rgb(174, 174, 184)),
            );
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if Self::pill_button(ui, "Tune", self.show_tune).clicked() {
                    self.show_tune = !self.show_tune;
                }
            });
        });
        ui.add_space(4.0);

        ui.horizontal(|ui| {
            ui.label(RichText::new("Speaker").size(10.5).weak());
            for mode in DspPresetSpeaker::ALL {
                let active = self.ctrl.dsp_state.speaker_mode == mode
                    && !self.ctrl.element_host_enabled;
                if Self::pill_button(ui, mode.title(), active).clicked() {
                    let mut next = self.ctrl.dsp_state.clone();
                    next.apply_speaker_mode(mode);
                    self.ctrl.element_host_enabled = false;
                    self.ctrl.update_dsp_config(next);
                }
            }
        });

        ui.add_space(4.0);
        ui.horizontal(|ui| {
            ui.label(RichText::new("Tone EQ").size(10.5).weak());
            for tone in DspPresetTone::ALL {
                let active =
                    self.ctrl.dsp_state.tone_mode == tone && !self.ctrl.element_host_enabled;
                if Self::pill_button(ui, tone.title(), active).clicked() {
                    let mut next = self.ctrl.dsp_state.clone();
                    next.apply_tone_mode(tone);
                    self.ctrl.element_host_enabled = false;
                    self.ctrl.update_dsp_config(next);
                }
            }
        });

        if self.show_tune {
            ui.add_space(6.0);
            Self::card_frame().show(ui, |ui| {
                let mut next = self.ctrl.dsp_state.clone();
                let mut changed = false;

                ui.horizontal(|ui| {
                    ui.label(RichText::new("Crossfeed").size(11.0));
                    changed |= ui
                        .add(Slider::new(&mut next.crossfeed, 0.0..=1.0).show_value(false))
                        .changed();
                    ui.label(RichText::new(format!("{}%", (next.crossfeed * 100.0).round() as i32)).size(10.5));
                });
                ui.horizontal(|ui| {
                    ui.label(RichText::new("Room     ").size(11.0));
                    changed |= ui
                        .add(Slider::new(&mut next.room, 0.0..=1.0).show_value(false))
                        .changed();
                    ui.label(RichText::new(format!("{}%", (next.room * 100.0).round() as i32)).size(10.5));
                });
                ui.horizontal(|ui| {
                    ui.label(RichText::new("Bass     ").size(11.0));
                    changed |= ui
                        .add(Slider::new(&mut next.bass_db, -6.0..=6.0).show_value(false))
                        .changed();
                    ui.label(RichText::new(format!("{:+.1} dB", next.bass_db)).size(10.5));
                });
                ui.horizontal(|ui| {
                    ui.label(RichText::new("Mid      ").size(11.0));
                    changed |= ui
                        .add(Slider::new(&mut next.mid_db, -6.0..=6.0).show_value(false))
                        .changed();
                    ui.label(RichText::new(format!("{:+.1} dB", next.mid_db)).size(10.5));
                });
                ui.horizontal(|ui| {
                    ui.label(RichText::new("Treble   ").size(11.0));
                    changed |= ui
                        .add(Slider::new(&mut next.treble_db, -6.0..=6.0).show_value(false))
                        .changed();
                    ui.label(RichText::new(format!("{:+.1} dB", next.treble_db)).size(10.5));
                });
                changed |= ui
                    .checkbox(&mut next.limiter_enabled, "Safe Headroom Soft Limiter")
                    .changed();

                if changed {
                    self.ctrl.update_dsp_config(next);
                }
            });
        }
    }

    fn render_input_section(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.label(
                RichText::new("Input")
                    .size(12.0)
                    .strong()
                    .color(Color32::from_rgb(174, 174, 184)),
            );
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let guard_label = if self.ctrl.bt_mic_guard_enabled {
                    "BT Mic Guard On"
                } else {
                    "BT Mic Guard Off"
                };
                if Self::pill_button(ui, guard_label, self.ctrl.bt_mic_guard_enabled).clicked() {
                    self.ctrl.bt_mic_guard_enabled = !self.ctrl.bt_mic_guard_enabled;
                    if self.ctrl.bt_mic_guard_enabled {
                        self.ctrl.enforce_bt_mic_guard();
                    }
                }
            });
        });
        ui.add_space(4.0);

        let inputs: Vec<_> = self
            .ctrl
            .devices
            .iter()
            .filter(|d| d.is_input)
            .cloned()
            .collect();

        Self::card_frame().show(ui, |ui| {
            for dev in inputs {
                let selected = dev.is_default_input;
                let dot = if selected { "●" } else { "○" };
                if ui
                    .selectable_label(
                        selected,
                        RichText::new(format!("{}  {} ({})", dot, dev.name, dev.transport))
                            .size(12.0),
                    )
                    .clicked()
                {
                    self.ctrl.select_input_device(&dev.id);
                }
            }
        });
    }

    fn render_app_mixer_section(&mut self, ui: &mut egui::Ui) {
        let custom = self.ctrl.has_custom_app_changes();
        ui.horizontal(|ui| {
            let arrow = if self.show_app_mixer { "▾" } else { "▸" };
            if ui
                .selectable_label(
                    false,
                    RichText::new(format!("{}  App Mixer & Routing", arrow))
                        .size(12.0)
                        .strong(),
                )
                .clicked()
            {
                self.show_app_mixer = !self.show_app_mixer;
            }
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if self.show_app_mixer || custom {
                    let btn = ui.add_enabled(
                        custom,
                        Button::new(RichText::new("Reset to Default").size(10.5))
                            .corner_radius(CornerRadius::same(5)),
                    );
                    if btn.clicked() {
                        self.ctrl.reset_all_app_streams();
                    }
                } else {
                    ui.label(RichText::new("Default").size(10.5).weak());
                }
            });
        });

        if !self.show_app_mixer {
            return;
        }

        let outputs: Vec<_> = self
            .ctrl
            .devices
            .iter()
            .filter(|d| d.is_output)
            .cloned()
            .collect();
        let apps: Vec<AppAudioStream> = self.ctrl.apps.clone();

        Self::card_frame().show(ui, |ui| {
            for app in apps {
                ui.horizontal(|ui| {
                    let dot_color = if app.is_producing_audio {
                        Color32::from_rgb(52, 199, 89)
                    } else {
                        Color32::from_rgb(90, 90, 98)
                    };
                    ui.label(RichText::new("●").size(8.0).color(dot_color));
                    ui.label(RichText::new(&app.app_name).size(11.5).strong());

                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        let mut selected_target = app.target_device_id.clone().unwrap_or_default();
                        let cur_name = outputs
                            .iter()
                            .find(|d| d.id == selected_target)
                            .map(|d| d.name.clone())
                            .unwrap_or_else(|| "System Default".to_string());
                        ComboBox::from_id_salt(format!("route_{}", app.id))
                            .selected_text(cur_name)
                            .width(120.0)
                            .show_ui(ui, |ui| {
                                if ui
                                    .selectable_value(
                                        &mut selected_target,
                                        String::new(),
                                        "System Default",
                                    )
                                    .clicked()
                                {
                                    self.ctrl.route_app(&app.id, None);
                                }
                                for dev in &outputs {
                                    if ui
                                        .selectable_value(
                                            &mut selected_target,
                                            dev.id.clone(),
                                            &dev.name,
                                        )
                                        .clicked()
                                    {
                                        self.ctrl.route_app(&app.id, Some(&dev.id));
                                    }
                                }
                            });
                    });
                });

                ui.horizontal(|ui| {
                    let mute_label = if app.is_muted { "Muted" } else { "Vol" };
                    if Self::pill_button(ui, mute_label, app.is_muted).clicked() {
                        self.ctrl.toggle_app_mute(&app.id);
                    }
                    let mut vol = app.volume;
                    let slider = ui.add_enabled(
                        !app.is_muted,
                        Slider::new(&mut vol, 0.0..=2.0).show_value(false),
                    );
                    if slider.changed() {
                        self.ctrl.set_app_volume(&app.id, vol);
                    }
                    if ui
                        .selectable_label(false, format!("{}%", (vol * 100.0).round() as i32))
                        .clicked()
                    {
                        self.ctrl.set_app_volume(&app.id, 1.0);
                    }
                });
                ui.add_space(4.0);
            }
        });
    }

    fn render_loopback_section(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            let arrow = if self.show_loopback { "▾" } else { "▸" };
            if ui
                .selectable_label(
                    false,
                    RichText::new(format!("{}  Loopback & Recorder", arrow))
                        .size(12.0)
                        .strong(),
                )
                .clicked()
            {
                self.show_loopback = !self.show_loopback;
            }
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let badge = if self.ctrl.is_recording {
                    "Recording"
                } else if self.ctrl.loopback_active {
                    "Live"
                } else {
                    "Off"
                };
                ui.label(RichText::new(badge).size(10.5).weak());
            });
        });

        if !self.show_loopback {
            return;
        }

        let bus_options = self.ctrl.loopback_bus_options();
        Self::card_frame().show(ui, |ui| {
            ui.horizontal(|ui| {
                let mut lb = self.ctrl.loopback_active;
                if ui.checkbox(&mut lb, "Loopback to Virtual Input").changed() {
                    self.ctrl.set_loopback_active(lb);
                }
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    let has_mix = self.ctrl.has_custom_loopback_mix();
                    if ui
                        .add_enabled(has_mix, Button::new(RichText::new("Reset Mix").size(10.5)))
                        .clicked()
                    {
                        self.ctrl.reset_loopback_mix();
                    }
                });
            });

            ui.horizontal(|ui| {
                ui.label(RichText::new("Target Bus").size(10.5).weak());
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    ComboBox::from_id_salt("loopback_bus")
                        .selected_text(&self.ctrl.loopback_target_bus)
                        .width(195.0)
                        .show_ui(ui, |ui| {
                            for b in &bus_options {
                                ui.selectable_value(
                                    &mut self.ctrl.loopback_target_bus,
                                    b.clone(),
                                    b,
                                );
                            }
                        });
                });
            });

            ui.separator();

            // Microphone channel
            ui.horizontal(|ui| {
                ui.checkbox(&mut self.ctrl.loopback_include_mic, "Mic");
                let mut gain = self.ctrl.loopback_mic_gain;
                if ui
                    .add_enabled(
                        self.ctrl.loopback_include_mic,
                        Slider::new(&mut gain, 0.0..=2.5).show_value(false),
                    )
                    .changed()
                {
                    self.ctrl.loopback_mic_gain = gain;
                }
                ui.label(RichText::new(format!("{}%", (gain * 100.0).round() as i32)).size(10.5));
            });

            // System audio master
            ui.horizontal(|ui| {
                ui.label(RichText::new("System Audio").size(11.0));
                ui.add(Slider::new(&mut self.ctrl.loopback_sys_gain, 0.0..=2.0).show_value(false));
                ui.label(
                    RichText::new(format!(
                        "{}%",
                        (self.ctrl.loopback_sys_gain * 100.0).round() as i32
                    ))
                    .size(10.5),
                );
            });

            // Per-app loopback mix channels
            let app_ids: Vec<(String, String)> = self
                .ctrl
                .apps
                .iter()
                .map(|a| (a.id.clone(), a.app_name.clone()))
                .collect();
            for (app_id, app_name) in app_ids {
                if let Some(ch) = self.ctrl.loopback_channels.get_mut(&app_id) {
                    ui.horizontal(|ui| {
                        ui.checkbox(&mut ch.included, &app_name);
                        ui.add_enabled(
                            ch.included,
                            Slider::new(&mut ch.gain, 0.0..=2.0).show_value(false),
                        );
                        ui.label(
                            RichText::new(if ch.included {
                                format!("{}%", (ch.gain * 100.0).round() as i32)
                            } else {
                                "Off".to_string()
                            })
                            .size(10.5),
                        );
                    });
                }
            }

            ui.separator();

            ui.horizontal(|ui| {
                let rec_label = if self.ctrl.is_recording {
                    "Stop Recording"
                } else {
                    "Record Internal Audio (WAV)"
                };
                if Self::pill_button(ui, rec_label, self.ctrl.is_recording).clicked() {
                    if self.ctrl.is_recording {
                        if let Some(p) = self.ctrl.stop_recording() {
                            self.status_flash = Some(format!("Saved: {}", p.display()));
                        }
                    } else if let Ok(p) = self.ctrl.start_recording(None) {
                        let mut sample_buf = vec![0.1f32; 1024 * 2];
                        let _ = self.ctrl.process_and_record_frames(&mut sample_buf);
                        self.status_flash = Some(format!("Recording -> {}", p.display()));
                    }
                }
            });
        });
    }

    fn render_external_vst_section(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            let arrow = if self.show_external_chain {
                "▾"
            } else {
                "▸"
            };
            if ui
                .selectable_label(
                    false,
                    RichText::new(format!("{}  External VST3 / AU Chain", arrow))
                        .size(12.0)
                        .strong(),
                )
                .clicked()
            {
                self.show_external_chain = !self.show_external_chain;
            }
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let badge = if self.ctrl.element_host_enabled {
                    "Active"
                } else {
                    "Optional"
                };
                ui.label(RichText::new(badge).size(10.5).weak());
            });
        });

        if !self.show_external_chain {
            return;
        }

        Self::card_frame().show(ui, |ui| {
            ui.checkbox(&mut self.ctrl.element_host_enabled, "Route via Element Host (OSC)");
            for idx in 0..self.ctrl.element_slots.len() {
                let (name, bypassed) = self.ctrl.element_slots[idx].clone();
                ui.horizontal(|ui| {
                    if Self::pill_button(ui, &name, !bypassed).clicked() {
                        self.ctrl.send_element_slot_bypass(idx, !bypassed);
                    }
                });
            }
        });
    }
}

impl eframe::App for AudioMatrixDesktopApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let panel_frame = Frame::new()
            .fill(Color32::from_rgb(24, 24, 28))
            .inner_margin(Margin::same(12));

        egui::CentralPanel::default()
            .frame(panel_frame)
            .show(ui, |ui| {
                ScrollArea::vertical().show(ui, |ui| {
                    ui.set_min_width(ui.available_width());
                    self.render_output_section(ui);
                    ui.add_space(6.0);
                    ui.separator();
                    ui.add_space(6.0);
                    self.render_dsp_section(ui);
                    ui.add_space(6.0);
                    ui.separator();
                    ui.add_space(6.0);
                    self.render_input_section(ui);
                    ui.add_space(6.0);
                    ui.separator();
                    ui.add_space(6.0);
                    self.render_app_mixer_section(ui);
                    ui.add_space(4.0);
                    self.render_loopback_section(ui);
                    ui.add_space(4.0);
                    self.render_external_vst_section(ui);

                    if let Some(ref msg) = self.status_flash {
                        ui.add_space(6.0);
                        ui.label(RichText::new(msg).size(10.0).color(Color32::from_rgb(52, 199, 89)));
                    }

                    ui.add_space(8.0);
                    ui.separator();
                    ui.horizontal(|ui| {
                        if ui.button("Refresh").clicked() {
                            self.ctrl.refresh_all();
                        }
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            ui.label(
                                RichText::new(format!(
                                    "Rust Core v2.0.0 ({})",
                                    self.ctrl.backend_kind.name()
                                ))
                                .size(10.0)
                                .weak(),
                            );
                        });
                    });
                });
            });
    }
}
