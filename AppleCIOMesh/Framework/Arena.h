// Copyright © 2026 Apple Inc. All Rights Reserved.

// APPLE INC.
// PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
// PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
// IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
// 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
// 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
// 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
// 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
// You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
// EA1937
// 10/02/2024

#pragma once
#include <cstddef>
#include <mach/vm_statistics.h>
#include <sys/mman.h>

class [[gnu::visibility("hidden")]] MeshArena
{
	void * const m_memory;
	const size_t m_capacity;
	size_t m_allocated                = 0;
	size_t m_offset                   = 0;
	size_t m_locked_offset            = 0;
	size_t m_max_locked_offset        = 0;
	static constexpr size_t kPageSize = 16ull * 1024;
	MeshArena(void * memory, size_t capacity) : m_memory(memory), m_capacity(capacity)
	{
	}

  public:
	/**
	 * Creates a new Arena of the specified capacity.
	 * The caller is responsible of freeing this arena (using operator delete).
	 * If creation fails, this function returns nullptr.
	 */
	static MeshArena *
	create(size_t capacity)
	{
		// Align the capacity on page size
		capacity      = (capacity + kPageSize - 1) & ~(kPageSize - 1);
		int fd        = VM_MAKE_TAG(VM_MEMORY_IOSURFACE);
		auto * memory = mmap(nullptr, capacity, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, fd, 0 /* offset */);
		if (memory == MAP_FAILED) {
			return nullptr;
		}
		return new MeshArena{memory, capacity};
	}

	~MeshArena()
	{
		if (m_memory) {
			munlock(m_memory, m_max_locked_offset);
			munmap(m_memory, m_capacity);
		}
	}

	MeshArena(MeshArena const &)             = delete;
	MeshArena & operator=(MeshArena const &) = delete;

	/**
	 * Allocates the specified number of bytes in the arena.
	 * If there is not enough space, this function will return nullptr.
	 */
	void *
	alloc(size_t bufferSize)
	{
		const auto alignment  = alignof(max_align_t);
		size_t aligned_offset = (m_offset + alignment - 1) & ~(alignment - 1);
		if (aligned_offset + bufferSize > m_capacity) {
			return nullptr;
		}
		void * result = (unsigned char *)m_memory + aligned_offset;
		m_offset      = aligned_offset + bufferSize;

		// This is less than what we actually allocated (because alignment adds to it).
		// However, this is purely to keep track of how much was requested so when dealloc is called
		// we know when to reset the whole arena.
		m_allocated += bufferSize;
		return result;
	}

	/**
	 * Locks the specified size into RAM preventing that memory from being paged to swap.
	 * This avoids incurring a page fault when the memory is accessed later.
	 */
	void
	lock(size_t bufferSize)
	{
		if (m_locked_offset < m_offset) {
			// In case alloc is called with a larger number than hint.
			// Or if alloc is called prior without a corresponding prefault().
			m_locked_offset = m_offset;
		}
		const auto alignment        = alignof(max_align_t);
		const size_t aligned_offset = (m_locked_offset + alignment - 1) & ~(alignment - 1);
		if (aligned_offset + bufferSize > m_capacity) {
			return;
		}

		void * mem      = (unsigned char *)m_memory + aligned_offset;
		m_locked_offset = aligned_offset + bufferSize;
		if (m_locked_offset > m_max_locked_offset) {
			m_max_locked_offset = m_locked_offset;
			mlock(mem, bufferSize);
		}
	}

	/**
	 * This function does not actually deallocate the bytes. However, if the number of bytes
	 * deallocated is equal to the total number of the bytes allocated the arena will reset itself.
	 * The order in which you call dealloc does not have to match the order of alloc.
	 *
	 */
	size_t
	dealloc(size_t bufferSize)
	{
		m_allocated -= bufferSize;
		if (m_allocated == 0) {
			reset();
		}
		return m_allocated;
	}

	/**
	 * Clears the arena and resets its size back to zero.
	 */
	void
	reset()
	{
		m_offset        = 0;
		m_locked_offset = 0;
	}
};
