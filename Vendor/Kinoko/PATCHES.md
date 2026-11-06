# Kinoko (vendored)

Mario Kart Wii physics engine by vabold and contributors, MIT licensed (see LICENSE),
from https://github.com/vabold/Kinoko. Built into the `kinoko-drive` helper that Driver's View
runs for game-accurate driving (see `drive.cc`; the `kinoko-drive` Xcode target builds it).

Local changes:
- `source/host/main.cc` removed; `drive.cc` is the entry point.
- `MapdataCheckPoint.cc`: `std::views::enumerate` replaced with an index (libc++ lacks it).
- `KReplaySystem.cc`: added `#include <sstream>`.
- Getters added: `RaceManager::Player::currentLap()`, `ObjectDirector::objects()`,
  `ObjectBase::mapObj()`.
