# wmtr macOS-side build.
#   make host     libwmtr_host.dylib (arm64): host executor + DXMT's winemetal_unix.c + airconv
#   make server   wmtr-server (arm64): standalone executor for the two-process prototype
#   make client-macos  winemetal.so (x86_64 Mach-O): client unixlib for macOS Wine (socket transport)
#   make test     build and run tests/wmtr_loopback
# Linux (x86-64 build box, CC=gcc):
#   make client-linux  winemetal.so (x86-64 ELF): guest client unixlib (virtio-gpu transport), glibc <= 2.14 symbols
#   make test-linux    build and run tests/wmtr_ntdll_test against it
# Inputs: DXMT source at the pinned revision (DXMT=), its native build dir with libairconv.a (DXMT_BUILD=),
# LLVM 15 static libs (LLVM=).
DXMT ?= /Volumes/LEANWORK/dxmt
DXMT_BUILD ?= $(DXMT)/build-native
LLVM ?= /Volumes/LEANWORK/toolchains/llvm15
OUT ?= build
CC = clang

INC = -Iinclude -Isrc -I$(DXMT)/src/winemetal -I$(DXMT)/src/airconv
CFLAGS = -O2 -g -Wall -Wno-unused-function $(INC)
FRAMEWORKS = -framework Foundation -framework Metal -framework MetalFX -framework QuartzCore -framework Cocoa \
             -framework CoreGraphics -framework ColorSync -framework CoreFoundation
LLVM_LIBS = -L$(LLVM)/lib -lLLVMPasses -lLLVMTarget -lLLVMObjCARCOpts -lLLVMCoroutines -lLLVMipo \
  -lLLVMInstrumentation -lLLVMVectorize -lLLVMLinker -lLLVMIRReader -lLLVMAsmParser -lLLVMFrontendOpenMP \
  -lLLVMScalarOpts -lLLVMInstCombine -lLLVMAggressiveInstCombine -lLLVMTransformUtils -lLLVMBitWriter \
  -lLLVMAnalysis -lLLVMProfileData -lLLVMSymbolize -lLLVMDebugInfoPDB -lLLVMDebugInfoMSF -lLLVMDebugInfoDWARF \
  -lLLVMObject -lLLVMTextAPI -lLLVMMCParser -lLLVMMC -lLLVMDebugInfoCodeView -lLLVMBitReader -lLLVMCore \
  -lLLVMRemarks -lLLVMBitstreamReader -lLLVMBinaryFormat -lLLVMSupport -lLLVMDemangle \
  /opt/homebrew/opt/zstd/lib/libzstd.a -lz -lcurses -lxml2 -lc++
AIRCONV = $(DXMT_BUILD)/src/airconv/darwin/libairconv.a $(DXMT_BUILD)/libs/DXBCParser/libDXBCParserNative.a

all: host server client-macos

$(OUT):
	mkdir -p $(OUT)

# DXMT's unix side, unchanged; its unix-call table becomes wmtr_impl_funcs
$(OUT)/winemetal_unix.o: $(DXMT)/src/winemetal/unix/winemetal_unix.c | $(OUT)
	$(CC) $(CFLAGS) -ObjC -D__wine_unix_call_funcs=wmtr_impl_funcs -D__wine_unix_call_wow64_funcs=wmtr_impl_wow64_funcs \
	  -Wno-deprecated-declarations -c $< -o $@
$(OUT)/cache.o: $(DXMT)/src/winemetal/unix/cache.c | $(OUT)
	$(CC) $(CFLAGS) -ObjC -c $< -o $@
$(OUT)/wmtr_host.o: src/wmtr_host.m include/*.h src/wmtr_calls.inc | $(OUT)
	$(CC) $(CFLAGS) -ObjC -c $< -o $@

host: $(OUT)/libwmtr_host.dylib
$(OUT)/libwmtr_host.dylib: $(OUT)/wmtr_host.o $(OUT)/winemetal_unix.o $(OUT)/cache.o $(AIRCONV)
	$(CC) -dynamiclib -install_name @rpath/libwmtr_host.dylib -o $@ $^ $(LLVM_LIBS) $(FRAMEWORKS) -lsqlite3
	codesign -s - -f $@

server: $(OUT)/wmtr-server
$(OUT)/wmtr-server: src/server_main.m $(OUT)/libwmtr_host.dylib
	$(CC) $(CFLAGS) -o $@ src/server_main.m -L$(OUT) -lwmtr_host -Wl,-rpath,@executable_path $(FRAMEWORKS)
	codesign -s - -f $@

client-macos: $(OUT)/x86_64-macos/winemetal.so
$(OUT)/x86_64-macos/winemetal.so: src/wmtr_client.c src/transport_sock.c include/*.h src/*.inc
	mkdir -p $(OUT)/x86_64-macos
	$(CC) -arch x86_64 $(CFLAGS) -shared -fPIC -o $@ src/wmtr_client.c src/transport_sock.c -Wl,-undefined,dynamic_lookup
	codesign -s - -f $@

test: $(OUT)/wmtr_loopback $(OUT)/wmtr_present_test
	./$(OUT)/wmtr_loopback
	./$(OUT)/wmtr_present_test
$(OUT)/wmtr_present_test: tests/wmtr_present_test.m $(OUT)/libwmtr_host.dylib
	$(CC) $(CFLAGS) -o $@ tests/wmtr_present_test.m -L$(OUT) -lwmtr_host -Wl,-rpath,@executable_path -framework Cocoa -framework Metal -framework QuartzCore
$(OUT)/wmtr_loopback: tests/wmtr_loopback.m src/wmtr_host.m src/wmtr_client.c include/*.h | $(OUT)
	$(CC) $(CFLAGS) -o $@ tests/wmtr_loopback.m src/wmtr_host.m src/wmtr_client.c -framework Foundation -framework Metal -framework Cocoa -framework QuartzCore

# -mtls-dialect=gnu: newer GCC defaults to TLS descriptors, which need GLIBC_ABI_GNU2_TLS (absent in the
# Steam Runtime's and the FEX rootfs's glibc), so the unixlib would not load
LINUX_CFLAGS = -O2 -g -Wall -Wno-unused-function -mtls-dialect=gnu $(INC) -include include/wmtr_glibc_compat.h
client-linux: $(OUT)/x86_64-linux/winemetal.so
$(OUT)/x86_64-linux/winemetal.so: src/wmtr_client.c src/transport_virtgpu.c include/*.h src/*.inc
	mkdir -p $(OUT)/x86_64-linux
	$(CC) $(LINUX_CFLAGS) -shared -fPIC -o $@ src/wmtr_client.c src/transport_virtgpu.c -lpthread -ldl
test-linux: $(OUT)/x86_64-linux/winemetal.so
	mkdir -p $(OUT)/x86_64-linux/standin
	$(CC) -shared -fPIC -o $(OUT)/x86_64-linux/standin/ntdll.so tests/ntdll_standin.c
	$(CC) -O2 -o $(OUT)/x86_64-linux/wmtr_ntdll_test tests/wmtr_ntdll_test.c -ldl
	./$(OUT)/x86_64-linux/wmtr_ntdll_test $(abspath $(OUT))/x86_64-linux/standin/ntdll.so $(abspath $(OUT))/x86_64-linux/winemetal.so
	@# loads in the Steam Runtime: no glibc version newer than 2.14 and no TLS-descriptor ABI requirement
	@if readelf -V $< | grep -E 'GLIBC_ABI_|GLIBC_2\.(1[5-9]|[2-9][0-9])'; then echo "FAIL: glibc requirement too new"; exit 1; fi
	@echo "glibc requirements: ok"

clean:
	rm -rf $(OUT)
.PHONY: all host server client-macos client-linux test test-linux clean
