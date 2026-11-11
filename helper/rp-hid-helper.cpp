// rp-hid-helper — root helper that owns a Karabiner DriverKit virtual mouse for RemotePointer.
//
// Why: macOS (and Universal Control) treat a virtual HID device like real hardware, but the Karabiner driver only
// accepts clients running as root. The menu-bar app sends pointer reports here over a Unix socket; only the user
// whose uid is given on the command line may connect.
//
// Usage:  rp-hid-helper <allowed-uid>      serve /var/run/remote-pointer-hid.sock
//         rp-hid-helper --test             draw a circle with the virtual mouse, then exit
//
// Wire format: fixed 16-byte messages, little-endian.
//   type 1 pointing:  u8 1, u8 buttons, i16 dx, i16 dy, i8 vwheel, i8 hwheel, 8 bytes padding
//   type 2..5 key state (full set of keys currently down; an empty set releases everything):
//     u8 type, u8 modifiers (keyboard only), u8 count (≤6), u8 pad, u16 usages[6]
//     2 = keyboard (page 0x07), 3 = consumer (page 0x0C), 4 = Apple vendor keyboard (0xFF01), 5 = Apple top case (0x00FF)

#include <pqrs/karabiner/driverkit/virtual_hid_device_driver.hpp>
#include <pqrs/karabiner/driverkit/virtual_hid_device_service.hpp>
#include <atomic>
#include <cmath>
#include <csignal>
#include <iostream>
#include <mutex>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>

namespace hid = pqrs::karabiner::driverkit::virtual_hid_device_driver::hid_report;
namespace svc = pqrs::karabiner::driverkit::virtual_hid_device_service;

static const char* kSocketPath = "/var/run/remote-pointer-hid.sock";
static std::atomic<bool> ready{false};
static std::atomic<bool> quit{false};
static std::mutex client_mutex;
static std::unique_ptr<svc::client> client;

struct __attribute__((packed)) Message {
  uint8_t type;
  uint8_t buttons;   // pointing: buttons; keys: modifiers
  union {
    struct __attribute__((packed)) { int16_t dx, dy; int8_t vwheel, hwheel; uint8_t pad[8]; } p;
    struct __attribute__((packed)) { uint8_t count, pad; uint16_t usages[6]; } k;
  };
};
static_assert(sizeof(Message) == 16);
static std::atomic<bool> keyboard_ready{false};

template <typename Report>
static void post_keys(const Message& m, Report r) {
  for (int i = 0; i < std::min<int>(m.k.count, 6); ++i) r.keys.insert(m.k.usages[i]);
  client->async_post_report(r);
}

static void post_key_message(const Message& m) {
  std::lock_guard<std::mutex> lock(client_mutex);
  if (!client || !keyboard_ready) return;
  switch (m.type) {
    case 2: {
      hid::keyboard_input r;
      for (int b = 0; b < 8; ++b)
        if (m.buttons & (1 << b)) r.modifiers.insert(static_cast<hid::modifier>(1 << b));
      post_keys(m, r);
      break;
    }
    case 3: post_keys(m, hid::consumer_input{}); break;
    case 4: post_keys(m, hid::apple_vendor_keyboard_input{}); break;
    case 5: post_keys(m, hid::apple_vendor_top_case_input{}); break;
  }
}

static void release_all_keys() {
  for (uint8_t t = 2; t <= 5; ++t) { Message m{}; m.type = t; post_key_message(m); }
}

static void post(uint8_t buttons, int dx, int dy, int vw, int hw) {
  std::lock_guard<std::mutex> lock(client_mutex);
  if (!client || !ready) return;
  // Reports carry 8-bit deltas; split larger moves into several reports.
  do {
    int sx = std::clamp(dx, -127, 127), sy = std::clamp(dy, -127, 127);
    hid::pointing_input r;
    for (int b = 0; b < 8; ++b)
      if (buttons & (1 << b)) r.buttons.insert(b + 1);
    r.x = static_cast<uint8_t>(static_cast<int8_t>(sx));
    r.y = static_cast<uint8_t>(static_cast<int8_t>(sy));
    r.vertical_wheel = static_cast<uint8_t>(static_cast<int8_t>(vw));
    r.horizontal_wheel = static_cast<uint8_t>(static_cast<int8_t>(hw));
    client->async_post_report(r);
    dx -= sx; dy -= sy; vw = 0; hw = 0;
  } while (dx != 0 || dy != 0);
}

static bool read_full(int fd, void* buf, size_t n) {
  auto* p = static_cast<uint8_t*>(buf);
  while (n > 0) {
    ssize_t r = read(fd, p, n);
    if (r <= 0) return false;
    p += r; n -= static_cast<size_t>(r);
  }
  return true;
}

static void serve(uid_t allowed) {
  unlink(kSocketPath);
  int s = socket(AF_UNIX, SOCK_STREAM, 0);
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  strlcpy(addr.sun_path, kSocketPath, sizeof(addr.sun_path));
  if (bind(s, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) { perror("bind"); exit(1); }
  chmod(kSocketPath, 0666);   // access is checked per connection with getpeereid
  listen(s, 2);
  std::cout << "listening on " << kSocketPath << " for uid " << allowed << std::endl;
  while (!quit) {
    int c = accept(s, nullptr, nullptr);
    if (c < 0) continue;
    uid_t uid; gid_t gid;
    if (getpeereid(c, &uid, &gid) != 0 || (uid != allowed && uid != 0)) {
      std::cout << "rejected connection from uid " << uid << std::endl;
      close(c);
      continue;
    }
    std::cout << "client connected" << std::endl;
    Message m;
    uint8_t last_buttons = 0;
    while (read_full(c, &m, sizeof(m))) {
      if (m.type == 1) { post(m.buttons, m.p.dx, m.p.dy, m.p.vwheel, m.p.hwheel); last_buttons = m.buttons; }
      else post_key_message(m);
    }
    if (last_buttons) post(0, 0, 0, 0, 0);   // never leave a button or key held if the app goes away
    release_all_keys();
    std::cout << "client disconnected" << std::endl;
    close(c);
  }
}

int main(int argc, char** argv) {
  if (argc < 2) { std::cerr << "usage: rp-hid-helper <allowed-uid> | --test" << std::endl; return 2; }
  if (geteuid() != 0) { std::cerr << "must run as root" << std::endl; return 1; }
  bool test = std::string(argv[1]) == "--test";
  std::signal(SIGINT, [](int) { quit = true; _exit(0); });
  std::signal(SIGTERM, [](int) { quit = true; _exit(0); });
  std::signal(SIGPIPE, SIG_IGN);

  pqrs::dispatcher::extra::initialize_shared_dispatcher();
  client = std::make_unique<svc::client>();
  client->connected.connect([] { std::cout << "connected to daemon" << std::endl; 
    client->async_virtual_hid_pointing_initialize();
    svc::virtual_hid_keyboard_parameters kp;
    kp.set_country_code(pqrs::hid::country_code::us);
    client->async_virtual_hid_keyboard_initialize(kp);
  });
  client->virtual_hid_keyboard_ready.connect([](auto&& r) {
    if (r != keyboard_ready.exchange(r)) std::cout << "virtual keyboard ready: " << r << std::endl;
  });
  client->connect_failed.connect([](auto&& e) { std::cout << "connect_failed " << e << " (is Karabiner-VirtualHIDDevice-Daemon running?)" << std::endl; });
  client->error_occurred.connect([](auto&& e) { std::cout << "error " << e << std::endl; });
  client->driver_version_mismatched.connect([](auto&& m) { if (m) std::cout << "driver version mismatch" << std::endl; });
  client->virtual_hid_pointing_ready.connect([](auto&& r) {
    if (r != ready.exchange(r)) std::cout << "virtual mouse ready: " << r << std::endl;
  });
  client->async_start();

  if (test) {
    for (int i = 0; i < 100 && !ready; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(100));
    if (!ready) { std::cout << "virtual mouse never became ready" << std::endl; return 1; }
    for (int i = 0; i < 400; ++i) {
      post(0, int(std::cos(0.05 * i) * 12), int(std::sin(0.05 * i) * 12), 0, 0);
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    std::cout << "test done" << std::endl;
    return 0;
  }
  serve(static_cast<uid_t>(std::stoul(argv[1])));
  return 0;
}
