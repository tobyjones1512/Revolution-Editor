// kinoko-drive: runs one Mario Kart Wii race in Kinoko for Revolution Editor's Driver's View.
//
//   kinoko-drive <course id> <character> <vehicle> <auto drift 0|1> [ghost.rkg]
//
// Game files are read from $KINOKO_FILESYSTEM_ROOT (Race/Common.szs, Race/Course/<name>.szs).
// Each line on stdin runs one 60 fps frame: "<buttons> <stickX> <stickY> <trick>" (stick -1...1,
// buttons 1 accelerate, 2 brake/drift, 4 item; trick 0 none, 1 up..4 right; ignored for ghosts).
// Each frame answers with any course objects that moved ("o <gobj index> x y z"), then:
//   "k x y z qx qy qz qw speed stage lap checkpoint respawn raceMs flags"
// where flags is 1 in respawn, 2 in a cannon, 4 touching ground, 8 wrong way.

#include "host/SceneCreatorDynamic.hh"

#include <abstract/File.hh>
#include <egg/core/ExpHeap.hh>
#include <egg/core/SceneManager.hh>
#include <game/field/ObjectDirector.hh>
#include <game/kart/KartObjectManager.hh>
#include <game/system/CourseMap.hh>
#include <game/system/KPadDirector.hh>
#include <game/system/RaceConfig.hh>
#include <game/system/RaceManager.hh>
#include <game/system/TimerManager.hh>

#include <cstdio>
#include <cstdlib>
#include <vector>

using namespace Kinoko;

static Course s_course;
static Character s_character;
static Vehicle s_vehicle;
static bool s_autoDrift;
static u8 *s_ghost = nullptr;

static void OnInit(System::RaceConfig *config, void *) {
    auto &scenario = config->raceScenario();
    auto &player = scenario.players[0];
    if (s_ghost) {
        config->setGhost(s_ghost);
        player.type = System::RaceConfig::Player::Type::Ghost;
        return;
    }
    scenario.course = s_course;
    player.character = s_character;
    player.vehicle = s_vehicle;
    player.driftIsAuto = s_autoDrift;
    player.type = System::RaceConfig::Player::Type::Local;
}

int main(int argc, char **argv) {
#if defined(__arm64__) || defined(__aarch64__)
    uint64_t fpcr;
    asm("mrs %0, fpcr" : "=r"(fpcr));
    asm("msr fpcr, %0" ::"r"(fpcr | (1 << 24))); // flush denormals, as the Wii does
#endif
    if (argc < 5) {
        std::fprintf(stderr, "usage: kinoko-drive <course> <character> <vehicle> <autodrift> [ghost.rkg]\n");
        return 2;
    }
    s_course = static_cast<Course>(std::atoi(argv[1]));
    s_character = static_cast<Character>(std::atoi(argv[2]));
    s_vehicle = static_cast<Vehicle>(std::atoi(argv[3]));
    s_autoDrift = std::atoi(argv[4]) != 0;

    void *memory = std::malloc(MEMORY_SPACE_SIZE);
    auto *rootHeap = EGG::ExpHeap::create(memory, MEMORY_SPACE_SIZE, DEFAULT_OPT);
    rootHeap->setName("EGGRoot");
    rootHeap->becomeCurrentHeap();
    EGG::SceneManager::SetRootHeap(rootHeap);

    if (argc > 5) {
        size_t size = 0;
        s_ghost = Abstract::File::LoadHost(argv[5], size);
        if (size < System::RKG_HEADER_SIZE || size > sizeof(System::RawGhostFile)) {
            std::fprintf(stderr, "Not a ghost file (wrong size).\n");
            return 2;
        }
    }

    System::RaceConfig::RegisterInitCallback(OnInit, nullptr);
    auto *sceneMgr = EGG::egg_new<EGG::SceneManager>(EGG::egg_new<Host::SceneCreatorDynamic>());
    sceneMgr->changeScene(0);

    std::vector<EGG::Vector3f> lastObjectPos;
    char line[128];
    while (std::fgets(line, sizeof(line), stdin)) {
        if (!s_ghost) {
            unsigned buttons = 0, trick = 0;
            float x = 0, y = 0;
            std::sscanf(line, "%u %f %f %u", &buttons, &x, &y, &trick);
            x = x < -1 ? -1 : x > 1 ? 1 : x;
            y = y < -1 ? -1 : y > 1 ? 1 : y;
            System::KPadDirector::Instance()->hostController()->setInputs(
                    static_cast<u16>(buttons & 7), EGG::Vector2f(x, y),
                    static_cast<System::Trick>(trick <= 4 ? trick : 0));
        }
        sceneMgr->calc();

        const auto *courseMap = System::CourseMap::Instance();
        const auto &objects = Field::ObjectDirector::Instance()->objects();
        if (lastObjectPos.size() != objects.size()) {
            lastObjectPos.assign(objects.size(), EGG::Vector3f(1e30f, 1e30f, 1e30f));
        }
        for (size_t i = 0; i < objects.size(); ++i) {
            const auto &p = objects[i]->pos();
            if (p == lastObjectPos[i]) {
                continue;
            }
            lastObjectPos[i] = p;
            for (u16 g = 0; g < courseMap->getGeoObjCount(); ++g) {
                if (courseMap->getGeoObj(g) == objects[i]->mapObj()) {
                    std::printf("o %u %g %g %g\n", g, p.x, p.y, p.z);
                    break;
                }
            }
        }

        const auto *kart = Kart::KartObjectManager::Instance()->object(0);
        const auto *race = System::RaceManager::Instance();
        const auto &player = race->player();
        const auto &pos = kart->pos();
        const auto &rot = kart->fullRot();
        const auto &status = kart->status();
        // The game's own finish time once over the line (it interpolates within the frame).
        const auto timer = race->stage() >= System::RaceManager::Stage::FinishLocal ?
                player.raceTimer() : race->timerManager().currentTimer();
        u32 ms = race->timerManager().frameCounter() ? timer.min * 60000u + timer.sec * 1000u + timer.mil : 0;
        int flags = (kart->isInRespawn() ? 1 : 0) | (status.onBit(Kart::eStatus::InCannon) ? 2 : 0) |
                (status.onBit(Kart::eStatus::TouchingGround) ? 4 : 0) |
                (player.drivingWrongWay() ? 8 : 0);
        std::printf("k %g %g %g %g %g %g %g %g %d %d %u %d %u %d\n", pos.x, pos.y, pos.z, rot.v.x,
                rot.v.y, rot.v.z, rot.w, kart->speed(), static_cast<int>(race->stage()),
                player.currentLap(), player.checkpointId(), player.jugemId(), ms, flags);
        std::fflush(stdout);
    }
    return 0;
}
