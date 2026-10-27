# Sounds

Perry plays five cues from `App/Resources/Sounds`: `wake` (starts listening), `send` (a task starts), `receive` (Perry needs you), `done`, and `fail`.

## Source

Every note is a vibraphone recording, soft mallets, from the [Versilian Community Sample Library](https://github.com/sgossner/VCSL) (VCSL) by Versilian Studios, released under CC0 1.0. CC0 asks for no attribution; this credit is a courtesy.

## Recipe

`scripts/sounds/build-vibes.py <VCSL vibraphone folder> <output folder>` renders the five cues as WAV files:

- Each note is retuned to within 3 cents of equal temperament at A = 440 Hz, all in C major. VCSL names its notes one octave below scientific pitch; the script corrects that.
- The last note of each cue is doubled one octave lower at −10 dB for body.
- A 70 Hz high-pass filter runs first. A gate then removes the recording's room noise from the tails.
- A computed 0.35 s room is mixed in 20 dB under the dry signal.
- Loudness is set over 100 ms blocks: `receive` and `done` at −22 LUFS, `fail` at −23, `wake` at −24, `send` at −29. True peak stays at or below −3 dBFS.

Convert each WAV with `afconvert -f caff -d LEI16@48000 <cue>.wav <cue>.caf`. `SoundPlayer` plays the cues at 0.45 volume.

Earshot measured the finished set against nine macOS system sounds. The typicality z scores are: `done` −2.3, `fail` −3.0, `receive` −2.6, `send` −2.8, `wake` −2.0. Each tail ends below −99 dBFS.
