/* Timestamp pools left alive by an application that exits (KosmicKrisp 0048).
 *
 * Under virglrenderer a guest game that exits has its VkDevice destroyed with its query pools still alive. Their
 * chunks of the process' 32 shared Metal counter heaps (0037) must return with the device: without that, vkd3d-proton's
 * timestamp pools of 8192 used every heap after a few game launches and vkCreateQueryPool failed ("too many heaps
 * already allocated"). 40 rounds of: a device, 4 timestamp pools of 8192 with one timestamp written each, the device
 * destroyed without destroying the pools. Prints "RESULT: PASS|FAIL ...". Run through tests/run.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include <vulkan/vulkan.h>

#define ROUNDS 40
#define POOLS 4
#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("RESULT: FAIL round %d %s = %d\n", round, #x, r_); exit(1); } } while (0)

int main(void)
{
   int round = 0;
   VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3};
   VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
   VkInstance inst; CHECK(vkCreateInstance(&ici, NULL, &inst));
   uint32_t n = 1; VkPhysicalDevice pd; VkResult r = vkEnumeratePhysicalDevices(inst, &n, &pd);
   if ((r != VK_SUCCESS && r != VK_INCOMPLETE) || n < 1) { printf("RESULT: FAIL no physical device\n"); return 1; }

   for (round = 0; round < ROUNDS; round++) {
      float prio = 1;
      VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio};
      VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
      VkDevice dev; CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
      VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);
      VkCommandPoolCreateInfo cpi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
      VkCommandPool cp; CHECK(vkCreateCommandPool(dev, &cpi, NULL, &cp));
      VkCommandBufferAllocateInfo cba = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cp, .commandBufferCount = 1};
      VkCommandBuffer cb; CHECK(vkAllocateCommandBuffers(dev, &cba, &cb));
      VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
      CHECK(vkBeginCommandBuffer(cb, &bi));
      for (int i = 0; i < POOLS; i++) {
         VkQueryPoolCreateInfo qpi = {.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP, .queryCount = 8192};
         VkQueryPool pool; CHECK(vkCreateQueryPool(dev, &qpi, NULL, &pool));
         vkCmdResetQueryPool(cb, pool, 0, 1);
         vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, pool, 0);
      }
      CHECK(vkEndCommandBuffer(cb));
      VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
      CHECK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
      CHECK(vkQueueWaitIdle(q));
      vkDestroyCommandPool(dev, cp, NULL);
      vkDestroyDevice(dev, NULL);
   }
   printf("RESULT: PASS %d devices destroyed with %d live timestamp pools of 8192 each\n", ROUNDS, POOLS);
   vkDestroyInstance(inst, NULL);
   return 0;
}
