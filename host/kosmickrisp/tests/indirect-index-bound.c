/* Indexed indirect draws with robustBufferAccess2 stay in one render pass (KosmicKrisp 0106).
 *
 * vkd3d-proton turns on robustBufferAccess2 and Unreal Engine 5 draws with indexed indirect draws. KosmicKrisp could not
 * rely on Metal for the bound of the index buffer of such a draw on macOS 26 (KK_WORKAROUND_12: the Metal 4 indirect
 * draw takes the index buffer length in bytes but gives it to the GPU as a count of 4-byte words), so it copied the
 * indices of every such draw with a compute dispatch. A compute dispatch ends the Metal render pass, so each draw cost
 * two Metal encoders: Bodycam made 12,600 encoders per second and ran at 20 fps.
 *
 * 1. A draw that reads past the bound index range reads index 0 there: nothing is drawn (the indices after the range
 *    form a full-screen triangle).
 * 2. A draw that uses the last index of the range draws the full-screen triangle, also with 12-byte 16-bit and 32-bit
 *    ranges (not a multiple of 4 indices: Metal validation, on in assert mode, rejects an index buffer length that is
 *    not a multiple of the index size).
 * 3. 2000 indexed indirect draws in one render pass take less than 3 times as long as 2000 indirect draws.
 * Prints "RESULT: PASS|FAIL ...". Run through tests/run.sh. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>
#include "async-stress-spv.h"

#define DRAWS 2000
#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("RESULT: FAIL %s = %d\n", #x, r_); exit(1); } } while (0)

static VkDevice dev; static VkPhysicalDevice pd; static VkQueue q;

static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

static void *host_buffer(VkBufferUsageFlags usage, VkDeviceSize size, VkBuffer *buf)
{
   VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage};
   CHECK(vkCreateBuffer(dev, &bci, NULL, buf));
   VkMemoryRequirements req; vkGetBufferMemoryRequirements(dev, *buf, &req);
   VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
   uint32_t type = 0;
   while (!(req.memoryTypeBits & (1u << type)) || !(mp.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) type++;
   VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = type};
   VkDeviceMemory mem; CHECK(vkAllocateMemory(dev, &mai, NULL, &mem)); CHECK(vkBindBufferMemory(dev, *buf, mem, 0));
   void *map; CHECK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, &map));
   return map;
}

int main(void)
{
   setenv("MTL_DEBUG_LAYER", "1", 1); setenv("MTL_DEBUG_LAYER_ERROR_MODE", "assert", 1);
   VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_4};
   VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
   VkInstance inst; CHECK(vkCreateInstance(&ici, NULL, &inst));
   uint32_t n = 1; VkResult r = vkEnumeratePhysicalDevices(inst, &n, &pd);
   if ((r != VK_SUCCESS && r != VK_INCOMPLETE) || n < 1) { printf("RESULT: FAIL no physical device\n"); return 1; }
   float prio = 1;
   VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio};
   VkPhysicalDeviceRobustness2FeaturesEXT rb = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT, .robustBufferAccess2 = VK_TRUE};
   VkPhysicalDeviceMaintenance5Features m5 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_5_FEATURES, .pNext = &rb, .maintenance5 = VK_TRUE};
   VkPhysicalDeviceDynamicRenderingFeatures dr = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES, .pNext = &m5, .dynamicRendering = VK_TRUE};
   VkPhysicalDeviceFeatures2 f2 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &dr, .features.robustBufferAccess = VK_TRUE};
   const char *ext[] = {VK_EXT_ROBUSTNESS_2_EXTENSION_NAME};
   VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
      .enabledExtensionCount = 1, .ppEnabledExtensionNames = ext};
   CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
   vkGetDeviceQueue(dev, 0, 0, &q);

   VkFormat fmt = VK_FORMAT_R8G8B8A8_UNORM;
   VkImageCreateInfo imci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = fmt, .extent = {64, 64, 1},
      .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
      .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT};
   VkImage img; CHECK(vkCreateImage(dev, &imci, NULL, &img));
   VkMemoryRequirements req; vkGetImageMemoryRequirements(dev, img, &req);
   VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = __builtin_ctz(req.memoryTypeBits)};
   VkDeviceMemory mem; CHECK(vkAllocateMemory(dev, &mai, NULL, &mem)); CHECK(vkBindImageMemory(dev, img, mem, 0));
   VkImageViewCreateInfo vci = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = fmt,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
   VkImageView view; CHECK(vkCreateImageView(dev, &vci, NULL, &view));

   /* 4 indices are bound. The indices after them make the triangle of draw `past` full-screen if they are read. */
   VkBuffer ib, ind, rd;
   uint16_t *idx = host_buffer(VK_BUFFER_USAGE_INDEX_BUFFER_BIT, 64, &ib);
   const uint16_t indices[32] = {0, 1, 2, 0, /* end of the bound range */ 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2};
   memcpy(idx, indices, sizeof(indices));
   const uint32_t indices32[3] = {0, 1, 2};
   memcpy(idx + 16, indices32, sizeof(indices32));
   const VkDrawIndexedIndirectCommand past = {.indexCount = 3, .instanceCount = 1, .firstIndex = 3}, last = {.indexCount = 3, .instanceCount = 1, .firstIndex = 1};
   const VkDrawIndirectCommand plain = {.vertexCount = 3, .instanceCount = 1};
   const VkDrawIndexedIndirectCommand first = {.indexCount = 3, .instanceCount = 1};
   char *args = host_buffer(VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT, 128, &ind);
   memcpy(args, &past, sizeof(past)); memcpy(args + 32, &last, sizeof(last)); memcpy(args + 64, &plain, sizeof(plain));
   memcpy(args + 96, &first, sizeof(first));
   const uint8_t *pixels = host_buffer(VK_BUFFER_USAGE_TRANSFER_DST_BIT, 64 * 64 * 4, &rd);

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

   VkCommandPoolCreateInfo cpi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT};
   VkCommandPool cp; CHECK(vkCreateCommandPool(dev, &cpi, NULL, &cp));
   VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cp, .commandBufferCount = 1};
   VkCommandBuffer c; CHECK(vkAllocateCommandBuffers(dev, &cbai, &c));
   VkRenderingAttachmentInfo att = {.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
      .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE};
   VkRenderingInfo ri = {.sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = {{0, 0}, {64, 64}}, .layerCount = 1,
      .colorAttachmentCount = 1, .pColorAttachments = &att};
   VkViewport viewport = {0, 0, 64, 64, 0, 1}; VkRect2D scissor = {{0, 0}, {64, 64}};
   VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {64, 64, 1}};

   /* runs: 0 = one draw past the range, 1 = one draw with the last index, 2 = the last index of a 12-byte 16-bit range,
    * 3 = the last index of a 12-byte 32-bit range, 4..6 = DRAWS indexed, 7..9 = DRAWS not indexed */
   const VkDeviceSize bind_offset[4] = {0, 0, 0, 32}, bind_size[4] = {8, 8, 12, 12}, arg_offset[4] = {0, 32, 0, 96};
   int red[4]; double indexed = 1e9, plain_ms = 1e9;
   for (int run = 0; run < 10; run++) {
      const int draws = run < 4 ? 1 : DRAWS, b = run < 4 ? run : 1;
      const double t0 = now_ms();
      VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
      CHECK(vkBeginCommandBuffer(c, &bi));
      VkImageMemoryBarrier to_color = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
         .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .image = img,
         .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
         .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
      vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL, 0, NULL, 1, &to_color);
      vkCmdBeginRendering(c, &ri);
      vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
      vkCmdSetViewport(c, 0, 1, &viewport); vkCmdSetScissor(c, 0, 1, &scissor);
      vkCmdBindIndexBuffer2(c, ib, bind_offset[b], bind_size[b], run == 3 ? VK_INDEX_TYPE_UINT32 : VK_INDEX_TYPE_UINT16);
      for (int i = 0; i < draws; i++) {
         if (run < 7) vkCmdDrawIndexedIndirect(c, ind, arg_offset[b], 1, 0);
         else vkCmdDrawIndirect(c, ind, 64, 1, 0);
      }
      vkCmdEndRendering(c);
      VkImageMemoryBarrier to_copy = to_color;
      to_copy.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT; to_copy.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
      to_copy.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL; to_copy.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
      vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &to_copy);
      vkCmdCopyImageToBuffer(c, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rd, 1, &copy);
      VkMemoryBarrier to_host = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT};
      vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &to_host, 0, NULL, 0, NULL);
      CHECK(vkEndCommandBuffer(c));
      VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &c};
      CHECK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
      CHECK(vkQueueWaitIdle(q));
      const double ms = now_ms() - t0;
      if (run < 4) red[run] = pixels[(32 * 64 + 32) * 4];
      else if (run < 7) indexed = ms < indexed ? ms : indexed;
      else plain_ms = ms < plain_ms ? ms : plain_ms;
   }

   const int ok = red[0] == 0 && red[1] == 255 && red[2] == 255 && red[3] == 255 && indexed < 3 * plain_ms + 2;
   printf("RESULT: %s draw past the index range drew %s, draws with the last index drew %s, %d indexed indirect draws %.1f ms, not indexed %.1f ms\n",
          ok ? "PASS" : "FAIL", red[0] ? "a triangle" : "nothing", red[1] == 255 && red[2] == 255 && red[3] == 255 ? "the triangle" : "nothing",
          DRAWS, indexed, plain_ms);
   return !ok;
}
