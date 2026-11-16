/* A recorded command buffer that is never submitted (KosmicKrisp 0105).
 *
 * vkd3d-proton records a Vulkan command buffer for every D3D12 command list as soon as the list is created or reset.
 * A list that is closed and never executed leaves a recorded command buffer that is never submitted, and
 * ID3D12CommandAllocator::Reset resets its pool (vkResetCommandPool without flags). Since 0104 KosmicKrisp resets
 * the Metal command allocator then and gives it to the pool's next recording, but the Metal command buffer that was
 * never committed still owned the allocator memory of its recording: when it began again (or was released) Metal
 * freed that memory under the other recording, and the commit of that one crashed in
 * -[IOGPUMetal4CommandBuffer fillCommandBufferArgs:] (SIGSEGV at 0x80; three Bodycam sessions).
 * Each round records A and never submits it, resets the pool, records B (a buffer fill), records A again, submits B
 * and checks the fill. Round 0 uses vkResetCommandPool, round 1 vkResetCommandBuffer, round 2 vkFreeCommandBuffers
 * and a new command buffer, and so on. Prints "RESULT: PASS|FAIL ...". Run through tests/run.sh.
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#define ROUNDS 48
#define WORDS 1024
#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("RESULT: FAIL %s = %d\n", #x, r_); exit(1); } } while (0)

static void crashed(int sig)
{
   static const char msg[] = "RESULT: FAIL the driver crashed in the submission after an unsubmitted recording\n";
   (void)sig; (void)!write(1, msg, sizeof(msg) - 1); _exit(1);
}

int main(void)
{
   signal(SIGSEGV, crashed); signal(SIGBUS, crashed); signal(SIGABRT, crashed); signal(SIGTRAP, crashed);
   setvbuf(stdout, NULL, _IONBF, 0);
   VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3};
   VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
   VkInstance inst; CHECK(vkCreateInstance(&ici, NULL, &inst));
   uint32_t n = 1; VkPhysicalDevice pd; VkResult r = vkEnumeratePhysicalDevices(inst, &n, &pd);
   if ((r != VK_SUCCESS && r != VK_INCOMPLETE) || n < 1) { printf("RESULT: FAIL no physical device\n"); return 1; }
   float prio = 1;
   VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio};
   VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
   VkDevice dev; CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
   VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);

   VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = WORDS * 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
   VkBuffer buf; CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));
   VkMemoryRequirements req; vkGetBufferMemoryRequirements(dev, buf, &req);
   VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
   const VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
   uint32_t type = UINT32_MAX;
   for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
      if ((req.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) { type = i; break; }
   if (type == UINT32_MAX) { printf("RESULT: FAIL no host visible memory type\n"); return 1; }
   VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = type};
   VkDeviceMemory mem; CHECK(vkAllocateMemory(dev, &mai, NULL, &mem)); CHECK(vkBindBufferMemory(dev, buf, mem, 0));
   uint32_t *words; CHECK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, (void **)&words));

   VkCommandPoolCreateInfo cpi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT};
   VkCommandPool cp; CHECK(vkCreateCommandPool(dev, &cpi, NULL, &cp));
   VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cp, .commandBufferCount = 1};
   VkCommandBuffer a, b; CHECK(vkAllocateCommandBuffers(dev, &cbai, &a)); CHECK(vkAllocateCommandBuffers(dev, &cbai, &b));
   VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
   VkFence fence; CHECK(vkCreateFence(dev, &fci, NULL, &fence));
   const VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};

   for (uint32_t round = 0; round < ROUNDS; round++) {
      const uint32_t value = 0xb0d70000u + round;

      CHECK(vkBeginCommandBuffer(a, &bi)); vkCmdFillBuffer(a, buf, 0, VK_WHOLE_SIZE, 0xdeadbeefu); CHECK(vkEndCommandBuffer(a));
      switch (round % 3) {
      case 0: CHECK(vkResetCommandPool(dev, cp, 0)); break;
      case 1: CHECK(vkResetCommandBuffer(a, 0)); break;
      case 2: vkFreeCommandBuffers(dev, cp, 1, &a); break;
      }
      CHECK(vkBeginCommandBuffer(b, &bi)); vkCmdFillBuffer(b, buf, 0, VK_WHOLE_SIZE, value); CHECK(vkEndCommandBuffer(b));
      if (round % 3 == 2) CHECK(vkAllocateCommandBuffers(dev, &cbai, &a));
      CHECK(vkBeginCommandBuffer(a, &bi)); vkCmdFillBuffer(a, buf, 0, VK_WHOLE_SIZE, 0xdeadbeefu); CHECK(vkEndCommandBuffer(a));

      VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &b};
      CHECK(vkQueueSubmit(q, 1, &si, fence));
      CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX));
      CHECK(vkResetFences(dev, 1, &fence));
      for (uint32_t i = 0; i < WORDS; i++) {
         if (words[i] != value) { printf("RESULT: FAIL round %u word %u is %#x, not %#x\n", round, i, words[i], value); return 1; }
      }
   }
   CHECK(vkDeviceWaitIdle(dev));

   vkDestroyFence(dev, fence, NULL);
   vkDestroyCommandPool(dev, cp, NULL);
   vkDestroyBuffer(dev, buf, NULL);
   vkFreeMemory(dev, mem, NULL);
   vkDestroyDevice(dev, NULL);
   vkDestroyInstance(inst, NULL);
   printf("RESULT: PASS %d submissions after unsubmitted recordings\n", ROUNDS);
   return 0;
}
