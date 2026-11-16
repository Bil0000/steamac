/* Command buffers submitted again and again (KosmicKrisp 0104).
 *
 * vkd3d-proton submits the same recorded command buffers many times. KosmicKrisp records such a submission again on
 * a queue-owned command buffer (Metal command buffers are one-time use), and each recording takes a Metal command
 * allocator from the pool. Allocators went back to the pool at vkEndCommandBuffer, were reused without a reset, and
 * kept the memory of every command recorded with them: in a Bodycam match the allocators held 23 GiB and macOS ran out
 * of application memory. 8 command buffers of 10 render passes of 200 draws each are recorded once, then submitted in
 * turn 16000 times, each one again once its last submission completed. Passes when the process footprint grows by
 * less than 64 MiB after the first 100 submissions. Prints "RESULT: PASS|FAIL ...". Run through tests/run.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach/mach.h>
#include <vulkan/vulkan.h>
#include "async-stress-spv.h"

#define SUBMITS 16000
#define RING 8
#define PASSES 10
#define DRAWS 200
#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("RESULT: FAIL %s = %d\n", #x, r_); exit(1); } } while (0)

static double footprint_mib(void)
{
   task_vm_info_data_t info; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
   task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
   return info.phys_footprint / 1048576.0;
}

int main(void)
{
   VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3};
   VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
   VkInstance inst; CHECK(vkCreateInstance(&ici, NULL, &inst));
   uint32_t n = 1; VkPhysicalDevice pd; VkResult r = vkEnumeratePhysicalDevices(inst, &n, &pd);
   if ((r != VK_SUCCESS && r != VK_INCOMPLETE) || n < 1) { printf("RESULT: FAIL no physical device\n"); return 1; }
   float prio = 1;
   VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio};
   VkPhysicalDeviceDynamicRenderingFeatures dr = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES, .dynamicRendering = VK_TRUE};
   VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &dr, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
   VkDevice dev; CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
   VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);

   VkFormat fmt = VK_FORMAT_R8G8B8A8_UNORM;
   VkImageCreateInfo imci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = fmt, .extent = {64, 64, 1},
      .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT};
   VkImage img; CHECK(vkCreateImage(dev, &imci, NULL, &img));
   VkMemoryRequirements req; vkGetImageMemoryRequirements(dev, img, &req);
   VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = __builtin_ctz(req.memoryTypeBits)};
   VkDeviceMemory mem; CHECK(vkAllocateMemory(dev, &mai, NULL, &mem)); CHECK(vkBindImageMemory(dev, img, mem, 0));
   VkImageViewCreateInfo vci = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = fmt,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
   VkImageView view; CHECK(vkCreateImageView(dev, &vci, NULL, &view));
   VkShaderModuleCreateInfo smv = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(vs_spv), .pCode = (const uint32_t *)vs_spv};
   VkShaderModuleCreateInfo smf = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(fs_spv), .pCode = (const uint32_t *)fs_spv};
   VkShaderModule vs, fs; CHECK(vkCreateShaderModule(dev, &smv, NULL, &vs)); CHECK(vkCreateShaderModule(dev, &smf, NULL, &fs));
   VkPipelineLayoutCreateInfo plci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
   VkPipelineLayout layout; CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
   VkPipelineShaderStageCreateInfo st[2] = {
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main"},
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main"}};
   VkPipelineVertexInputStateCreateInfo vi = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
   VkPipelineInputAssemblyStateCreateInfo ia = {.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
   VkPipelineViewportStateCreateInfo vp = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1};
   VkPipelineRasterizationStateCreateInfo rs = {.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1};
   VkPipelineMultisampleStateCreateInfo ms = {.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
   VkPipelineColorBlendAttachmentState cba = {.colorWriteMask = 0xf};
   VkPipelineColorBlendStateCreateInfo cb = {.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &cba};
   VkDynamicState dyn[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
   VkPipelineDynamicStateCreateInfo ds = {.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2, .pDynamicStates = dyn};
   VkPipelineRenderingCreateInfo rc = {.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .colorAttachmentCount = 1, .pColorAttachmentFormats = &fmt};
   VkGraphicsPipelineCreateInfo gp = {.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &rc, .stageCount = 2, .pStages = st,
      .pVertexInputState = &vi, .pInputAssemblyState = &ia, .pViewportState = &vp, .pRasterizationState = &rs,
      .pMultisampleState = &ms, .pColorBlendState = &cb, .pDynamicState = &ds, .layout = layout};
   VkPipeline pipe; CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gp, NULL, &pipe));

   VkCommandPoolCreateInfo cpi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
   VkCommandPool cp; CHECK(vkCreateCommandPool(dev, &cpi, NULL, &cp));
   VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cp, .commandBufferCount = RING};
   VkCommandBuffer cbs[RING]; CHECK(vkAllocateCommandBuffers(dev, &cbai, cbs));
   VkRenderingAttachmentInfo att = {.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
      .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE};
   VkRenderingInfo ri = {.sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = {{0, 0}, {64, 64}}, .layerCount = 1,
      .colorAttachmentCount = 1, .pColorAttachments = &att};
   VkViewport viewport = {0, 0, 64, 64, 0, 1}; VkRect2D scissor = {{0, 0}, {64, 64}};
   for (int c = 0; c < RING; c++) {
      VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
      CHECK(vkBeginCommandBuffer(cbs[c], &bi));
      for (int p = 0; p < PASSES; p++) {
         vkCmdBeginRendering(cbs[c], &ri);
         vkCmdBindPipeline(cbs[c], VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
         vkCmdSetViewport(cbs[c], 0, 1, &viewport); vkCmdSetScissor(cbs[c], 0, 1, &scissor);
         for (int i = 0; i < DRAWS; i++) vkCmdDraw(cbs[c], 3, 1, 0, 0);
         vkCmdEndRendering(cbs[c]);
      }
      CHECK(vkEndCommandBuffer(cbs[c]));
   }

   VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT};
   VkFence fences[RING]; for (int i = 0; i < RING; i++) CHECK(vkCreateFence(dev, &fci, NULL, &fences[i]));
   double base = 0;
   for (int s = 0; s < SUBMITS; s++) {
      if (s == 100) base = footprint_mib();
      VkFence fence = fences[s % RING];
      CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX));
      CHECK(vkResetFences(dev, 1, &fence));
      VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cbs[s % RING]};
      CHECK(vkQueueSubmit(q, 1, &si, fence));
   }
   CHECK(vkDeviceWaitIdle(dev));
   sleep(2);
   const double grown = footprint_mib() - base;

   for (int i = 0; i < RING; i++) vkDestroyFence(dev, fences[i], NULL);
   vkDestroyCommandPool(dev, cp, NULL);
   vkDestroyPipeline(dev, pipe, NULL);
   vkDestroyPipelineLayout(dev, layout, NULL);
   vkDestroyShaderModule(dev, vs, NULL); vkDestroyShaderModule(dev, fs, NULL);
   vkDestroyImageView(dev, view, NULL); vkDestroyImage(dev, img, NULL);
   vkFreeMemory(dev, mem, NULL);
   vkDestroyDevice(dev, NULL);
   vkDestroyInstance(inst, NULL);
   printf("RESULT: %s footprint grew %.1f MiB over %d resubmissions\n", grown < 64 ? "PASS" : "FAIL", grown, SUBMITS - 100);
   return grown < 64 ? 0 : 1;
}
