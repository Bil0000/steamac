/* Timestamp pools and command buffers left alive by an application that exits (KosmicKrisp 0102).
 *
 * Under virglrenderer a guest game that exits has its VkDevice destroyed with its query pools and command pools still
 * alive. The chunks of the process' 32 shared Metal counter heaps its recorded command buffers hold (upstream 0045)
 * must return with the device: without that, every heap entry was taken after a few game launches and timestamps read
 * 0. 40 rounds of: a device, 4 timestamp pools of 8192 with every query written in one command buffer, the device
 * destroyed without destroying the pools or the command pool; the last timestamp of every round must not read 0.
 * Then, on one device, 8192 timestamps written in one command buffer outside a render pass, as vkd3d-proton does: one
 * counter heap resolve for consecutive ones (upstream 0064). The footprint must grow by less than 400 MiB (about
 * 240-290 MiB with 0064, 588 MiB without it) and all 8192 must become available. Then 20 timestamp pools of 8192, more than the heaps hold: all are created and a timestamp of the
 * last becomes available. Prints "RESULT: PASS|FAIL ...". Run through tests/run.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <vulkan/vulkan.h>

#define ROUNDS 40
#define POOLS 4
#define BATCH 8192
#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("RESULT: FAIL round %d %s = %d\n", round, #x, r_); exit(1); } } while (0)

static double footprint_mib(void)
{
   task_vm_info_data_t info; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
   task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
   return info.phys_footprint / 1048576.0;
}

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
      VkQueryPool last = VK_NULL_HANDLE;
      for (int i = 0; i < POOLS; i++) {
         VkQueryPoolCreateInfo qpi = {.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP, .queryCount = 8192};
         VkQueryPool pool; CHECK(vkCreateQueryPool(dev, &qpi, NULL, &pool));
         vkCmdResetQueryPool(cb, pool, 0, 8192);
         for (uint32_t j = 0; j < 8192; j++) vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, pool, j);
         last = pool;
      }
      CHECK(vkEndCommandBuffer(cb));
      VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
      CHECK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
      CHECK(vkQueueWaitIdle(q));
      uint64_t value[2];
      CHECK(vkGetQueryPoolResults(dev, last, 8191, 1, sizeof(value), value, sizeof(value), VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT));
      if (!value[0]) { printf("RESULT: FAIL round %d: the last timestamp read 0 (counter heap entries of a destroyed device kept)\n", round); return 1; }
      vkDestroyDevice(dev, NULL);
   }
   /* More timestamp pools than the 32 shared counter heaps hold (16 of 8192): every pool is still created
    * (pools take no entries since upstream 0045), and a timestamp written to the last one becomes available. */
   round = ROUNDS;
   {
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
      VkQueryPoolCreateInfo qpi = {.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP, .queryCount = BATCH};
      VkQueryPool batch; CHECK(vkCreateQueryPool(dev, &qpi, NULL, &batch));
      VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
      /* Metal's first commit of a device takes about 80 MiB once: keep it out of the measurement */
      CHECK(vkBeginCommandBuffer(cb, &bi));
      vkCmdResetQueryPool(cb, batch, 0, 1);
      CHECK(vkEndCommandBuffer(cb));
      CHECK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
      CHECK(vkQueueWaitIdle(q));
      CHECK(vkResetCommandPool(dev, cp, 0));
      const double before = footprint_mib();
      CHECK(vkBeginCommandBuffer(cb, &bi));
      vkCmdResetQueryPool(cb, batch, 0, BATCH);
      for (uint32_t i = 0; i < BATCH; i++) vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, batch, i);
      CHECK(vkEndCommandBuffer(cb));
      CHECK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
      CHECK(vkQueueWaitIdle(q));
      const double grown = footprint_mib() - before;
      static uint64_t values[BATCH][2];
      CHECK(vkGetQueryPoolResults(dev, batch, 0, BATCH, sizeof(values), values, sizeof(values[0]), VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT));
      uint32_t available = 0;
      for (uint32_t i = 0; i < BATCH; i++) available += values[i][1] != 0;
      if (grown >= 400 || available != BATCH) {
         printf("RESULT: FAIL %d timestamps in one command buffer: the footprint grew %.1f MiB, %u available\n", BATCH, grown, available);
         return 1;
      }
      vkDestroyQueryPool(dev, batch, NULL);
      CHECK(vkResetCommandPool(dev, cp, 0));
      VkQueryPool pool = VK_NULL_HANDLE;
      for (int i = 0; i < 20; i++) {
         VkQueryPoolCreateInfo qpi = {.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP, .queryCount = 8192};
         CHECK(vkCreateQueryPool(dev, &qpi, NULL, &pool));
      }
      CHECK(vkBeginCommandBuffer(cb, &bi));
      vkCmdResetQueryPool(cb, pool, 0, 1);
      vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, pool, 0);
      CHECK(vkEndCommandBuffer(cb));
      CHECK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
      CHECK(vkQueueWaitIdle(q));
      uint64_t value[2];
      CHECK(vkGetQueryPoolResults(dev, pool, 0, 1, sizeof(value), value, sizeof(value), VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT));
      if (!value[1]) { printf("RESULT: FAIL timestamp of the 20th pool never became available\n"); return 1; }
      vkDestroyCommandPool(dev, cp, NULL);
      vkDestroyDevice(dev, NULL);
   }
   printf("RESULT: PASS %d devices destroyed with %d live timestamp pools of 8192 each and their command buffers; 20 pools on one device; %d timestamps in one command buffer\n", ROUNDS, POOLS, BATCH);
   vkDestroyInstance(inst, NULL);
   return 0;
}
