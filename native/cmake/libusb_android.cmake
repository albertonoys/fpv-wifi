# libusb for Android, built from third_party/libusb (v1.0.30) as a static library, plus a pkg-config
# file so devourer's pkg_check_modules(libusb-1.0) finds its headers. The library itself is linked
# explicitly (target_link_libraries(devourer PUBLIC usb-1.0-static)).
set(_lu ${KEPYUR_ROOT}/third_party/libusb)

# libusb >= 1.0.30 includes a generated libusb/version_describe.h from core.c; every upstream build
# system runs build-aux/gen-describe.sh first, so do the same here (empty macro as a last resort).
set(_lu_gen ${CMAKE_BINARY_DIR}/libusb_gen)
execute_process(COMMAND sh ${_lu}/build-aux/gen-describe.sh ${_lu} ${_lu_gen}/version_describe.h
                RESULT_VARIABLE _lu_gen_rc)
if(NOT _lu_gen_rc EQUAL 0)
  file(WRITE ${_lu_gen}/version_describe.h "#define LIBUSB_DESCRIBE \"\"\n")
endif()

add_library(usb-1.0-static STATIC
  ${_lu}/libusb/core.c ${_lu}/libusb/descriptor.c ${_lu}/libusb/hotplug.c ${_lu}/libusb/io.c
  ${_lu}/libusb/strerror.c ${_lu}/libusb/sync.c
  ${_lu}/libusb/os/linux_usbfs.c ${_lu}/libusb/os/linux_netlink.c
  ${_lu}/libusb/os/events_posix.c ${_lu}/libusb/os/threads_posix.c)
target_include_directories(usb-1.0-static PRIVATE ${_lu}/android ${_lu}/libusb/os ${_lu_gen})
target_include_directories(usb-1.0-static PUBLIC ${_lu}/libusb)
target_compile_options(usb-1.0-static PRIVATE -w)
target_link_libraries(usb-1.0-static PUBLIC log)

set(_pcdir ${CMAKE_BINARY_DIR}/pkgconfig)
file(MAKE_DIRECTORY ${_pcdir})
file(WRITE ${_pcdir}/libusb-1.0.pc
"Name: libusb-1.0\nDescription: libusb (kepyur, built in-tree for Android)\nVersion: 1.0.30\nLibs:\nCflags: -I${_lu}/libusb\n")
set(ENV{PKG_CONFIG_LIBDIR} ${_pcdir})
set(ENV{PKG_CONFIG_PATH} ${_pcdir})
set(ENV{PKG_CONFIG_SYSROOT_DIR} "")
