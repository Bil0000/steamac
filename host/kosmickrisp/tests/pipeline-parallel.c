/* Many graphics pipelines created from ONE thread, as a game's render thread does on its first launch (its Venus
 * ring reaches the host driver on one thread).
 *
 * Each round: a fresh device, PIPELINES pipelines whose shaders are unique (a random specialization constant, so
 * neither Mesa's disk cache nor Metal's shader cache hits), each created on this thread, then one command buffer
 * that draws once with every pipeline (one occlusion query per draw), submitted and waited for. The wall time runs
 * from the first vkCreateGraphicsPipelines to the end of that wait, so a compile left on a worker is still counted.
 * Rounds: MESA_KK_ASYNC_PIPELINES=0 (Metal compiles on the calling thread), then =1 with a reusable command buffer
 * (draws of pipelines still compiling are re-recorded at submission) and =1 with a ONE_TIME_SUBMIT one (KosmicKrisp
 * keeps no command list to re-record it from: 0050, before which the whole buffer was lost and the queries timed
 * out). Every draw must pass samples in every round, and each =1 round must take at most 3/4 of the =0 round. An
 * untimed =0 round with other shaders runs first, so the =0 round does not pay alone for the process' cold start.
 * Last, the queue-order round (0050): =1, QUEUED pipelines queued, then one more created and drawn at once in a
 * ONE_TIME_SUBMIT buffer. That draw must not wait for the jobs queued before it: it must take at most half the time
 * the workers (one per CPU, at least 4) need to drain the queue, QUEUED compiles at the =0 round's average.
 * In each =1 round, every kk-pipe worker must run at this thread's QoS class or above (0050: macOS threads start at
 * the default class, and MTLCompilerService compiles at its caller's).
 * Prints "RESULT: PASS|FAIL ...". Run through tests/run.sh.
 */
#include <mach/mach.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <vulkan/vulkan.h>
#include "pipeline-parallel-spv.h"

#define PIPELINES 48
#define QUEUED 200
#define SIZE 64
#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("RESULT: FAIL %s = %d\n", #x, r_); exit(1); } } while (0)

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

/* Number of kk-pipe worker threads of this process below this thread's QoS class */
static int slow_workers(void)
{
   thread_act_array_t th; mach_msg_type_number_t n; int slow = 0;
   if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS) return -1;
   for (mach_msg_type_number_t i = 0; i < n; i++) {
      pthread_t t = pthread_from_mach_thread_np(th[i]); char name[64] = ""; qos_class_t q = QOS_CLASS_UNSPECIFIED; int rel;
      if (t) { pthread_getname_np(t, name, sizeof(name)); pthread_get_qos_class_np(t, &q, &rel); }
      if (strstr(name, "kk-pipe") && q < qos_class_self()) slow++;
      mach_port_deallocate(mach_task_self(), th[i]);
   }
   vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof(*th));
   return slow;
}

/* Creates `count` pipelines; draws all of them, or only the last one (`late`), whose creation then starts the clock. */
static double round_ms(VkPhysicalDevice pd, const char *mode, VkCommandBufferUsageFlags usage, uint32_t seed, int count,
                       int late)
{
   setenv("MESA_KK_ASYNC_PIPELINES", mode, 1);
   float prio = 1;
   VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio};
   VkPhysicalDeviceDynamicRenderingFeatures dr = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES, .dynamicRendering = VK_TRUE};
   VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &dr, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
   VkDevice dev; CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
   VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);

   VkFormat fmt = VK_FORMAT_R8G8B8A8_UNORM;
   VkImageCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = fmt,
      .extent = {SIZE, SIZE, 1}, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
      .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT};
   VkImage img; CHECK(vkCreateImage(dev, &ici, NULL, &img));
   VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev, img, &mr);
   VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
   uint32_t type = 0; while (!(mr.memoryTypeBits & (1u << type))) type++;
   VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = type};
   VkDeviceMemory mem; CHECK(vkAllocateMemory(dev, &mai, NULL, &mem)); CHECK(vkBindImageMemory(dev, img, mem, 0));
   VkImageViewCreateInfo vci = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = fmt,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
   VkImageView view; CHECK(vkCreateImageView(dev, &vci, NULL, &view));
   VkQueryPoolCreateInfo qpi = {.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_OCCLUSION, .queryCount = count};
   VkQueryPool pool; CHECK(vkCreateQueryPool(dev, &qpi, NULL, &pool));

   VkShaderModuleCreateInfo smv = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(vs_spv), .pCode = (const uint32_t *)vs_spv};
   VkShaderModuleCreateInfo smf = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(fs_spv), .pCode = (const uint32_t *)fs_spv};
   VkShaderModule vs, fs; CHECK(vkCreateShaderModule(dev, &smv, NULL, &vs)); CHECK(vkCreateShaderModule(dev, &smf, NULL, &fs));
   VkPipelineLayoutCreateInfo plci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
   VkPipelineLayout layout; CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
   uint32_t spec_value;
   VkSpecializationMapEntry entry = {0, 0, sizeof(spec_value)};
   VkSpecializationInfo spec = {1, &entry, sizeof(spec_value), &spec_value};
   VkPipelineShaderStageCreateInfo st[2] = {
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main", .pSpecializationInfo = &spec},
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main", .pSpecializationInfo = &spec}};
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

   VkCommandPoolCreateInfo cpi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
   VkCommandPool cp; CHECK(vkCreateCommandPool(dev, &cpi, NULL, &cp));
   VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cp, .commandBufferCount = 1};
   VkCommandBuffer cmd; CHECK(vkAllocateCommandBuffers(dev, &cbai, &cmd));

   VkPipeline p[QUEUED + 1];
   const int first = late ? count - 1 : 0;
   double t0 = now();
   for (int i = 0; i < count; i++) {
      if (i == first) t0 = now();
      spec_value = seed + i;
      CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gp, NULL, &p[i]));
   }
   const double created = now();
   VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = usage};
   CHECK(vkBeginCommandBuffer(cmd, &bi));
   vkCmdResetQueryPool(cmd, pool, 0, count);
   VkRenderingAttachmentInfo att = {.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view, .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
      .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE};
   VkRenderingInfo ri = {.sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = {{0, 0}, {SIZE, SIZE}}, .layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &att};
   vkCmdBeginRendering(cmd, &ri);
   VkViewport viewport = {0, 0, SIZE, SIZE, 0, 1}; VkRect2D scissor = {{0, 0}, {SIZE, SIZE}};
   vkCmdSetViewport(cmd, 0, 1, &viewport); vkCmdSetScissor(cmd, 0, 1, &scissor);
   for (int i = first; i < count; i++) {
      vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p[i]);
      vkCmdBeginQuery(cmd, pool, i, 0);
      vkCmdDraw(cmd, 3, 1, 0, 0);
      vkCmdEndQuery(cmd, pool, i);
   }
   vkCmdEndRendering(cmd);
   CHECK(vkEndCommandBuffer(cmd));
   VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd};
   CHECK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
   CHECK(vkQueueWaitIdle(q));
   const double done = now();

   uint64_t samples[QUEUED + 1];
   CHECK(vkGetQueryPoolResults(dev, pool, first, count - first, sizeof(samples), samples, sizeof(samples[0]), VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT));
   for (int i = 0; i < count - first; i++)
      if (samples[i] == 0) { printf("RESULT: FAIL MESA_KK_ASYNC_PIPELINES=%s: draw %d passed no samples\n", mode, i); exit(1); }
   printf("  MESA_KK_ASYNC_PIPELINES=%s%s: %d pipelines created in %.0f ms, drawn after %.0f ms%s\n", mode, usage ? " one-time-submit" : "",
          count - first, (created - t0) * 1e3, (done - t0) * 1e3, late ? " (behind the queued ones)" : "");
   const int slow = mode[0] == '1' ? slow_workers() : 0;
   if (slow) { printf("RESULT: FAIL MESA_KK_ASYNC_PIPELINES=%s: %d kk-pipe workers below this thread's QoS class\n", mode, slow); exit(1); }

   for (int i = 0; i < count; i++) vkDestroyPipeline(dev, p[i], NULL);
   vkDestroyCommandPool(dev, cp, NULL);
   vkDestroyPipelineLayout(dev, layout, NULL);
   vkDestroyShaderModule(dev, vs, NULL); vkDestroyShaderModule(dev, fs, NULL);
   vkDestroyQueryPool(dev, pool, NULL);
   vkDestroyImageView(dev, view, NULL); vkDestroyImage(dev, img, NULL); vkFreeMemory(dev, mem, NULL);
   vkDestroyDevice(dev, NULL);
   return (done - t0) * 1e3;
}

int main(void)
{
   VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3};
   VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
   VkInstance inst; CHECK(vkCreateInstance(&ici, NULL, &inst));
   uint32_t n = 1; VkPhysicalDevice pd; VkResult r = vkEnumeratePhysicalDevices(inst, &n, &pd);
   if ((r != VK_SUCCESS && r != VK_INCOMPLETE) || n < 1) { printf("RESULT: FAIL no physical device\n"); return 1; }
   uint32_t seed = (uint32_t)time(NULL) * 2654435761u ^ (uint32_t)getpid() << 16;
   round_ms(pd, "0", 0, seed + 0x30000, PIPELINES, 0);
   const double sync_ms = round_ms(pd, "0", 0, seed, PIPELINES, 0);
   const double async_ms = round_ms(pd, "1", 0, seed + 0x10000, PIPELINES, 0);
   const double once_ms = round_ms(pd, "1", VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, seed + 0x20000, PIPELINES, 0);
   const double late_ms = round_ms(pd, "1", VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, seed + 0x40000, QUEUED + 1, 1);
   vkDestroyInstance(inst, NULL);
   long cpus = sysconf(_SC_NPROCESSORS_ONLN);
   const double late_max = sync_ms / PIPELINES * QUEUED / (cpus > 4 ? cpus : 4) / 2;
   const int ok = async_ms <= sync_ms * 3 / 4 && once_ms <= sync_ms * 3 / 4 && late_ms <= late_max;
   printf("RESULT: %s %d unique pipelines from one thread (warm): %.0f ms synchronous, %.0f / %.0f ms (one-time-submit) "
          "with MESA_KK_ASYNC_PIPELINES=1 (%.1fx / %.1fx); a one-time-submit draw behind %d queued pipelines: %.0f ms "
          "(at most %.0f)\n", ok ? "PASS" : "FAIL", PIPELINES, sync_ms, async_ms, once_ms, sync_ms / async_ms,
          sync_ms / once_ms, QUEUED, late_ms, late_max);
   return !ok;
}
