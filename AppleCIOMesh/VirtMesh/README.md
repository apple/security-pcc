Copyright © 2026 Apple Inc. All Rights Reserved.

APPLE INC.
PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
EA1937
10/02/2024

# VirtMesh for distributed VRE

This sub-folder contains VirtMesh code to support distributed inferences on VRE. It contains two major components, a guest-side kext an a host-side plugin.

The guest-side kext is a kext implementation of CIOMesh kext interfaces, but inherently use Virt IO interfaces to transmit data, because CIO is not available in a virtual machine.

The host-side plugin is a virtualization framework plugin, which implements the Virt IO device and communicate with (1) the guest-side kext for guest-host data exchange and (2) other plugins from other virtual machines to transmit data across VMs.

For more details, please refer to:


## Guest Kext

The `Guest/` folder has the implementation of guest kexts, where two kexts are implemented:

1. A `AppleVirtMeshIOBridge` base class for setting up Virt IO interfaces to communicate data between guest and host.
2. A `AppleVirtMesh` class derived from `AppleVirtMeshIOBridge` to actually implement CIOMesh kext interfaces.

This separated base-derived classes make them easier to test:

1. We can first mount the VirtMeshIOridge to test Virt IO functionalities, without worrying any of mesh-related code interfering the test.
2. And then mount the VirtMesh kext to test mesh functionalities, with the confidence that Virt IO is already functional.

> Note:
>
> 1. The `AppleVirtMeshIOBridge` is only served for a base class. It compiles to a kext for testing purpose only, it should not be shipped because it doesn't have any mesh-related functionalities. The `AppleVirtMesh` should be shipped.
>
> 2. The IOVirtIOPrimaryMatch magic number 0x1a0e106b is used to match a Virt IO device in the guest OS. The 0x106b is Apple device's default vendor PCI ID, and 0x1a0e is the PCI device ID for VirtMesh device which I selected as the next available enum after kAvpStrongIdentityDevice, see Virtualization repo for more details.
>
> 3. The Guest kext's plist files are based on AppleVirtIO project's Entropy device settings, with added AppleVirtIOPCITransport settings to match the non-default device ID 0x106b provided by VirtMesh plugin.

## Host Plugin

The host plugin can be loaded and executed by the Virtualization framework, and it serves as an XPC endpoint, to communicate data with other plugins. Each VM has only one plugin with it.

The host plugin also implements a broker to coordinate all plugins in the host machine.

Both the plugin and the broker should be shipped.

## Tests

VirtMesh comes we a few unit tests (or more like integration tests) which are compiled as standalone GoogleTest binaries.

To use such tests, compile them using cmake, copy the compiled binary to the guest VM and execute them. Each test connects to a specific kext and exercises test cases to test that kext's interfaces:

1. `GuestVirtIOTest`: This tests the AppleVirtIO's Entropy device, if success, it means the AppleVirtIO is properly installed and set up in the guest. It's a check to see if VirtIO is installed, and does not test any VirtMesh interfaces.
