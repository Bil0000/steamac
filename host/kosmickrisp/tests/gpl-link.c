/* VK_EXT_graphics_pipeline_library: the four DXVK-style libraries (vertex input, pre-rasterization,
 * fragment shader, fragment output) linked with and without LINK_TIME_OPTIMIZATION render the same
 * pixels as a monolithic pipeline. The vertex colour is R8G8B8A8_UNORM (state only the vertex input
 * library has), the target is B8G8R8A8_UNORM with a constant blend (state only the fragment output
 * library has), so a link that loses either library's state shows in the pixel.
 * Exits 0 and prints "RESULT: PASS" when every variant matches; "RESULT: SKIP" without the extension. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>
#include "gpl-link-spv.h"

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("%s failed: %d\nRESULT: FAIL\n", #x, r_); exit(1); } } while (0)
#define W 4

static VkDevice dev;
static VkPhysicalDevice pd;
static VkQueue queue;
static VkPipelineLayout layout;
static VkShaderModule vsm, fsm;

static VkPipelineVertexInputStateCreateInfo vi;
static VkPipelineInputAssemblyStateCreateInfo ia;
static VkPipelineViewportStateCreateInfo vp;
static VkPipelineRasterizationStateCreateInfo rs;
static VkPipelineMultisampleStateCreateInfo ms;
static VkPipelineDepthStencilStateCreateInfo ds;
static VkPipelineColorBlendStateCreateInfo cb;
static VkPipelineDynamicStateCreateInfo dyn;
static VkPipelineRenderingCreateInfo rinfo;
static VkPipelineShaderStageCreateInfo stages[2];

static const VkFormat color_format = VK_FORMAT_B8G8R8A8_UNORM;

static void
init_state(void)
{
   static VkVertexInputBindingDescription b[2] = {{0, 8, VK_VERTEX_INPUT_RATE_VERTEX}, {1, 4, VK_VERTEX_INPUT_RATE_VERTEX}};
   static VkVertexInputAttributeDescription a[2] = {{0, 0, VK_FORMAT_R32G32_SFLOAT, 0}, {1, 1, VK_FORMAT_R8G8B8A8_UNORM, 0}};
   vi = (VkPipelineVertexInputStateCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, .vertexBindingDescriptionCount = 2,
        .pVertexBindingDescriptions = b, .vertexAttributeDescriptionCount = 2, .pVertexAttributeDescriptions = a};
   ia = (VkPipelineInputAssemblyStateCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
   vp = (VkPipelineViewportStateCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1};
   rs = (VkPipelineRasterizationStateCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1};
   ms = (VkPipelineMultisampleStateCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
   ds = (VkPipelineDepthStencilStateCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
   /* out = src * constant(0.5) + dst * 0 : only correct when the fragment output state arrives */
   static VkPipelineColorBlendAttachmentState att = {VK_TRUE, VK_BLEND_FACTOR_CONSTANT_COLOR, VK_BLEND_FACTOR_ZERO, VK_BLEND_OP_ADD,
        VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_ZERO, VK_BLEND_OP_ADD, 0xf};
   cb = (VkPipelineColorBlendStateCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &att,
        .blendConstants = {0.5f, 0.5f, 0.5f, 0.5f}};
   static VkDynamicState d[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
   dyn = (VkPipelineDynamicStateCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2, .pDynamicStates = d};
   rinfo = (VkPipelineRenderingCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .colorAttachmentCount = 1, .pColorAttachmentFormats = &color_format};
   stages[0] = (VkPipelineShaderStageCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vsm, .pName = "main"};
   stages[1] = (VkPipelineShaderStageCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fsm, .pName = "main"};
}

static VkPipeline
monolithic(void)
{
   VkGraphicsPipelineCreateInfo ci = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &rinfo, .stageCount = 2, .pStages = stages,
        .pVertexInputState = &vi, .pInputAssemblyState = &ia, .pViewportState = &vp, .pRasterizationState = &rs,
        .pMultisampleState = &ms, .pDepthStencilState = &ds, .pColorBlendState = &cb, .pDynamicState = &dyn, .layout = layout};
   VkPipeline p;
   CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p));
   return p;
}

static VkPipeline
library(VkGraphicsPipelineLibraryFlagsEXT part, VkPipelineCreateFlags extra)
{
   VkGraphicsPipelineLibraryCreateInfoEXT li = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_LIBRARY_CREATE_INFO_EXT, .flags = part};
   VkGraphicsPipelineCreateInfo ci = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &li,
        .flags = VK_PIPELINE_CREATE_LIBRARY_BIT_KHR | extra, .pDynamicState = &dyn, .layout = layout};
   switch (part) {
   case VK_GRAPHICS_PIPELINE_LIBRARY_VERTEX_INPUT_INTERFACE_BIT_EXT:
      ci.pVertexInputState = &vi; ci.pInputAssemblyState = &ia; break;
   case VK_GRAPHICS_PIPELINE_LIBRARY_PRE_RASTERIZATION_SHADERS_BIT_EXT:
      li.pNext = &rinfo; ci.stageCount = 1; ci.pStages = &stages[0]; ci.pViewportState = &vp; ci.pRasterizationState = &rs; break;
   case VK_GRAPHICS_PIPELINE_LIBRARY_FRAGMENT_SHADER_BIT_EXT:
      li.pNext = &rinfo; ci.stageCount = 1; ci.pStages = &stages[1]; ci.pMultisampleState = &ms; ci.pDepthStencilState = &ds; break;
   default: /* FRAGMENT_OUTPUT_INTERFACE */
      li.pNext = &rinfo; ci.pMultisampleState = &ms; ci.pColorBlendState = &cb; break;
   }
   VkPipeline p;
   CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p));
   return p;
}

static VkPipeline
link(VkPipeline libs[4], VkPipelineCreateFlags flags)
{
   VkPipelineLibraryCreateInfoKHR li = {VK_STRUCTURE_TYPE_PIPELINE_LIBRARY_CREATE_INFO_KHR, .libraryCount = 4, .pLibraries = libs};
   VkGraphicsPipelineCreateInfo ci = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &li, .flags = flags, .layout = layout};
   VkPipeline p;
   CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p));
   return p;
}

static uint32_t
find_mem(uint32_t bits, VkMemoryPropertyFlags want)
{
   VkPhysicalDeviceMemoryProperties mp;
   vkGetPhysicalDeviceMemoryProperties(pd, &mp);
   for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
      if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
         return i;
   printf("no memory type\nRESULT: FAIL\n");
   exit(1);
}

static VkBuffer
make_buffer(VkDeviceSize size, VkBufferUsageFlags usage, void **map)
{
   VkBufferCreateInfo bi = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage};
   VkBuffer b;
   CHECK(vkCreateBuffer(dev, &bi, NULL, &b));
   VkMemoryRequirements req;
   vkGetBufferMemoryRequirements(dev, b, &req);
   VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
        .memoryTypeIndex = find_mem(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)};
   VkDeviceMemory m;
   CHECK(vkAllocateMemory(dev, &ai, NULL, &m));
   CHECK(vkBindBufferMemory(dev, b, m, 0));
   CHECK(vkMapMemory(dev, m, 0, VK_WHOLE_SIZE, 0, map));
   return b;
}

/* Draws one triangle covering the target and returns the centre pixel (B8G8R8A8 as a uint32). */
static uint32_t
render(VkPipeline p)
{
   VkImageCreateInfo ii = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = color_format,
        .extent = {W, W, 1}, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT};
   VkImage img;
   CHECK(vkCreateImage(dev, &ii, NULL, &img));
   VkMemoryRequirements req;
   vkGetImageMemoryRequirements(dev, img, &req);
   VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = find_mem(req.memoryTypeBits, 0)};
   VkDeviceMemory im;
   CHECK(vkAllocateMemory(dev, &ai, NULL, &im));
   CHECK(vkBindImageMemory(dev, img, im, 0));
   VkImageViewCreateInfo vci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = color_format,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
   VkImageView view;
   CHECK(vkCreateImageView(dev, &vci, NULL, &view));

   float *pos; uint32_t *col, *out;
   VkBuffer pb = make_buffer(24, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, (void **)&pos);
   VkBuffer cbuf = make_buffer(12, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, (void **)&col);
   VkBuffer ob = make_buffer(W * W * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, (void **)&out);
   const float tri[6] = {-1, -1, 3, -1, -1, 3};
   memcpy(pos, tri, sizeof(tri));
   for (int i = 0; i < 3; i++)
      col[i] = 0xff40c080; /* RGBA8 bytes 80 c0 40 ff */

   VkCommandPoolCreateInfo pci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
   VkCommandPool pool;
   CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool));
   VkCommandBufferAllocateInfo cai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
   VkCommandBuffer cmd;
   CHECK(vkAllocateCommandBuffers(dev, &cai, &cmd));
   VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
   CHECK(vkBeginCommandBuffer(cmd, &bi));
   VkImageMemoryBarrier bar = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .image = img,
        .subresourceRange = vci.subresourceRange, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED};
   vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL, 0, NULL, 1, &bar);
   VkRenderingAttachmentInfo ca = {VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view, .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE};
   VkRenderingInfo ri = {VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = {{0, 0}, {W, W}}, .layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &ca};
   vkCmdBeginRendering(cmd, &ri);
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p);
   VkViewport v = {0, 0, W, W, 0, 1};
   VkRect2D s = {{0, 0}, {W, W}};
   vkCmdSetViewport(cmd, 0, 1, &v);
   vkCmdSetScissor(cmd, 0, 1, &s);
   VkBuffer vbs[2] = {pb, cbuf};
   VkDeviceSize offs[2] = {0, 0};
   vkCmdBindVertexBuffers(cmd, 0, 2, vbs, offs);
   vkCmdDraw(cmd, 3, 1, 0, 0);
   vkCmdEndRendering(cmd);
   bar.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT; bar.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
   bar.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL; bar.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
   vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &bar);
   VkBufferImageCopy r = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {W, W, 1}};
   vkCmdCopyImageToBuffer(cmd, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, ob, 1, &r);
   CHECK(vkEndCommandBuffer(cmd));
   VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd};
   CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
   CHECK(vkQueueWaitIdle(queue));
   uint32_t px = out[(W / 2) * W + W / 2];
   vkDestroyCommandPool(dev, pool, NULL);
   vkDestroyImageView(dev, view, NULL);
   vkDestroyImage(dev, img, NULL); /* memory and buffers leak until exit: a test */
   return px;
}

int
main(void)
{
   VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3};
   VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
   VkInstance inst;
   CHECK(vkCreateInstance(&ici, NULL, &inst));
   uint32_t n = 1;
   vkEnumeratePhysicalDevices(inst, &n, &pd);
   if (!n) { printf("no device\nRESULT: FAIL\n"); return 1; }

   uint32_t ne = 0;
   vkEnumerateDeviceExtensionProperties(pd, NULL, &ne, NULL);
   VkExtensionProperties *ep = calloc(ne, sizeof(*ep));
   vkEnumerateDeviceExtensionProperties(pd, NULL, &ne, ep);
   int have = 0;
   for (uint32_t i = 0; i < ne; i++)
      have += !strcmp(ep[i].extensionName, VK_EXT_GRAPHICS_PIPELINE_LIBRARY_EXTENSION_NAME) ||
              !strcmp(ep[i].extensionName, VK_KHR_PIPELINE_LIBRARY_EXTENSION_NAME);
   if (have != 2) { printf("VK_EXT_graphics_pipeline_library not advertised\nRESULT: SKIP\n"); return 0; }

   VkPhysicalDeviceGraphicsPipelineLibraryPropertiesEXT gp = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_GRAPHICS_PIPELINE_LIBRARY_PROPERTIES_EXT};
   VkPhysicalDeviceProperties2 p2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &gp};
   vkGetPhysicalDeviceProperties2(pd, &p2);
   printf("fastLinking %u independentInterpolationDecoration %u\n", gp.graphicsPipelineLibraryFastLinking,
          gp.graphicsPipelineLibraryIndependentInterpolationDecoration);

   VkPhysicalDeviceGraphicsPipelineLibraryFeaturesEXT gf = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_GRAPHICS_PIPELINE_LIBRARY_FEATURES_EXT, .graphicsPipelineLibrary = VK_TRUE};
   VkPhysicalDeviceVulkan13Features f13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, .pNext = &gf, .dynamicRendering = VK_TRUE};
   const char *exts[2] = {VK_KHR_PIPELINE_LIBRARY_EXTENSION_NAME, VK_EXT_GRAPHICS_PIPELINE_LIBRARY_EXTENSION_NAME};
   float prio = 1;
   VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio};
   VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f13, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
        .enabledExtensionCount = 2, .ppEnabledExtensionNames = exts};
   CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
   vkGetDeviceQueue(dev, 0, 0, &queue);

   VkPipelineLayoutCreateInfo lci = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
   CHECK(vkCreatePipelineLayout(dev, &lci, NULL, &layout));
   VkShaderModuleCreateInfo smv = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(vs_spv), .pCode = (const uint32_t *)vs_spv};
   VkShaderModuleCreateInfo smf = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(fs_spv), .pCode = (const uint32_t *)fs_spv};
   CHECK(vkCreateShaderModule(dev, &smv, NULL, &vsm));
   CHECK(vkCreateShaderModule(dev, &smf, NULL, &fsm));
   init_state();

   /* B8G8R8A8 of RGBA (0x80,0xc0,0x40,0xff) * 0.5 = (0x40,0x60,0x20,0x80): 0x80402060 */
   const uint32_t expect = 0x80402060;
   uint32_t ref = render(monolithic());
   int fail = 0;
   printf("monolithic         %08x (expect %08x)\n", ref, expect);
   /* rounding of 0.5 * x may differ by one; accept +-1 per channel against the expectation */
   for (int c = 0; c < 32; c += 8) {
      int d = (int)((ref >> c) & 0xff) - (int)((expect >> c) & 0xff);
      if (d < -1 || d > 1) fail = 1;
   }

   static const VkGraphicsPipelineLibraryFlagsEXT parts[4] = {
      VK_GRAPHICS_PIPELINE_LIBRARY_VERTEX_INPUT_INTERFACE_BIT_EXT, VK_GRAPHICS_PIPELINE_LIBRARY_PRE_RASTERIZATION_SHADERS_BIT_EXT,
      VK_GRAPHICS_PIPELINE_LIBRARY_FRAGMENT_SHADER_BIT_EXT, VK_GRAPHICS_PIPELINE_LIBRARY_FRAGMENT_OUTPUT_INTERFACE_BIT_EXT};
   static const struct { const char *name; VkPipelineCreateFlags lib, link; } variants[] = {
      {"fast link", 0, 0},
      {"LTO, retained", VK_PIPELINE_CREATE_RETAIN_LINK_TIME_OPTIMIZATION_INFO_BIT_EXT, VK_PIPELINE_CREATE_LINK_TIME_OPTIMIZATION_BIT_EXT},
   };
   for (unsigned v = 0; v < sizeof(variants) / sizeof(variants[0]); v++) {
      VkPipeline libs[4];
      for (int i = 0; i < 4; i++)
         libs[i] = library(parts[i], variants[v].lib);
      VkPipeline p = link(libs, variants[v].link);
      /* libraries may be destroyed once linked */
      for (int i = 0; i < 4; i++)
         vkDestroyPipeline(dev, libs[i], NULL);
      uint32_t px = render(p);
      printf("%-18s %08x %s\n", variants[v].name, px, px == ref ? "ok" : "MISMATCH");
      fail |= px != ref;
      vkDestroyPipeline(dev, p, NULL);
   }
   printf("RESULT: %s\n", fail ? "FAIL" : "PASS");
   return fail;
}
