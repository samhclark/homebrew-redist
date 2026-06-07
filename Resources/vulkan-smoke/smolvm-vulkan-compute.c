#include <vulkan/vulkan.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ELEMENT_COUNT 256u
#define LOCAL_SIZE 64u
#define SHADER_PATH "/usr/libexec/smolvm-vulkan-smoke/compute.spv"

_Static_assert(ELEMENT_COUNT % LOCAL_SIZE == 0,
               "element count must be divisible by the shader local size");

static void fail(const char *message) {
  fprintf(stderr, "smolvm Vulkan compute smoke failed: %s\n", message);
  exit(EXIT_FAILURE);
}

static void check_vk(VkResult result, const char *operation) {
  if (result != VK_SUCCESS) {
    fprintf(stderr, "smolvm Vulkan compute smoke failed: %s returned %d\n",
            operation, result);
    exit(EXIT_FAILURE);
  }
}

static uint32_t *read_shader(const char *path, size_t *word_count) {
  FILE *file = fopen(path, "rb");
  long size;
  uint32_t *words;

  if (file == NULL) {
    fail("could not open compute shader");
  }
  if (fseek(file, 0, SEEK_END) != 0 || (size = ftell(file)) <= 0 ||
      size % (long)sizeof(uint32_t) != 0 || fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    fail("invalid compute shader size");
  }

  words = malloc((size_t)size);
  if (words == NULL || fread(words, 1, (size_t)size, file) != (size_t)size) {
    free(words);
    fclose(file);
    fail("could not read compute shader");
  }

  fclose(file);
  *word_count = (size_t)size / sizeof(uint32_t);
  return words;
}

static uint32_t find_memory_type(
    const VkPhysicalDeviceMemoryProperties *properties,
    uint32_t type_bits,
    VkMemoryPropertyFlags required) {
  for (uint32_t index = 0; index < properties->memoryTypeCount; index++) {
    if ((type_bits & (1u << index)) != 0 &&
        (properties->memoryTypes[index].propertyFlags & required) == required) {
      return index;
    }
  }
  fail("no host-visible coherent Vulkan memory type");
  return 0;
}

int main(void) {
  const char *shader_path = getenv("SMOLVM_VULKAN_SHADER");
  const VkApplicationInfo application_info = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "smolvm-vulkan-compute",
      .applicationVersion = VK_MAKE_VERSION(1, 0, 0),
      .pEngineName = "none",
      .engineVersion = VK_MAKE_VERSION(1, 0, 0),
      .apiVersion = VK_API_VERSION_1_0,
  };
  const VkInstanceCreateInfo instance_info = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &application_info,
  };
  VkInstance instance;
  uint32_t physical_device_count = 0;
  VkPhysicalDevice *physical_devices;
  VkPhysicalDevice physical_device = VK_NULL_HANDLE;
  VkPhysicalDeviceProperties physical_properties;
  uint32_t queue_family_count = 0;
  VkQueueFamilyProperties *queue_families;
  uint32_t queue_family_index = UINT32_MAX;
  float queue_priority = 1.0f;
  VkDeviceQueueCreateInfo queue_info;
  VkDeviceCreateInfo device_info;
  VkDevice device;
  VkQueue queue;
  VkBuffer buffer;
  VkMemoryRequirements memory_requirements;
  VkPhysicalDeviceMemoryProperties memory_properties;
  VkDeviceMemory memory;
  uint32_t *mapped_values;
  VkDescriptorSetLayout descriptor_set_layout;
  VkPipelineLayout pipeline_layout;
  size_t shader_word_count;
  uint32_t *shader_words;
  VkShaderModule shader_module;
  VkPipeline pipeline;
  VkDescriptorPool descriptor_pool;
  VkDescriptorSet descriptor_set;
  VkCommandPool command_pool;
  VkCommandBuffer command_buffer;
  VkFence fence;

  check_vk(vkCreateInstance(&instance_info, NULL, &instance),
           "vkCreateInstance");
  check_vk(vkEnumeratePhysicalDevices(instance, &physical_device_count, NULL),
           "vkEnumeratePhysicalDevices");
  if (physical_device_count == 0) {
    fail("no Vulkan physical devices");
  }

  physical_devices = calloc(physical_device_count, sizeof(*physical_devices));
  if (physical_devices == NULL) {
    fail("could not allocate physical-device list");
  }
  check_vk(vkEnumeratePhysicalDevices(instance, &physical_device_count,
                                      physical_devices),
           "vkEnumeratePhysicalDevices");
  for (uint32_t index = 0; index < physical_device_count; index++) {
    VkPhysicalDeviceProperties properties;

    vkGetPhysicalDeviceProperties(physical_devices[index], &properties);
    if (strstr(properties.deviceName, "Virtio-GPU Venus") != NULL &&
        strstr(properties.deviceName, "llvmpipe") == NULL) {
      physical_device = physical_devices[index];
      physical_properties = properties;
      break;
    }
  }
  free(physical_devices);
  if (physical_device == VK_NULL_HANDLE) {
    fail("no hardware-backed Virtio-GPU Venus device");
  }

  vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count,
                                           NULL);
  queue_families = calloc(queue_family_count, sizeof(*queue_families));
  if (queue_families == NULL) {
    fail("could not allocate queue-family list");
  }
  vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count,
                                           queue_families);
  for (uint32_t index = 0; index < queue_family_count; index++) {
    if ((queue_families[index].queueFlags & VK_QUEUE_COMPUTE_BIT) != 0) {
      queue_family_index = index;
      break;
    }
  }
  free(queue_families);
  if (queue_family_index == UINT32_MAX) {
    fail("selected Venus device has no compute queue");
  }

  queue_info = (VkDeviceQueueCreateInfo){
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = queue_family_index,
      .queueCount = 1,
      .pQueuePriorities = &queue_priority,
  };
  device_info = (VkDeviceCreateInfo){
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &queue_info,
  };
  check_vk(vkCreateDevice(physical_device, &device_info, NULL, &device),
           "vkCreateDevice");
  vkGetDeviceQueue(device, queue_family_index, 0, &queue);

  {
    const VkBufferCreateInfo buffer_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = ELEMENT_COUNT * sizeof(uint32_t),
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    check_vk(vkCreateBuffer(device, &buffer_info, NULL, &buffer),
             "vkCreateBuffer");
  }
  vkGetBufferMemoryRequirements(device, buffer, &memory_requirements);
  vkGetPhysicalDeviceMemoryProperties(physical_device, &memory_properties);
  {
    const uint32_t memory_type = find_memory_type(
        &memory_properties, memory_requirements.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
            VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    const VkMemoryAllocateInfo memory_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = memory_requirements.size,
        .memoryTypeIndex = memory_type,
    };
    check_vk(vkAllocateMemory(device, &memory_info, NULL, &memory),
             "vkAllocateMemory");
  }
  check_vk(vkBindBufferMemory(device, buffer, memory, 0),
           "vkBindBufferMemory");
  check_vk(vkMapMemory(device, memory, 0, memory_requirements.size, 0,
                       (void **)&mapped_values),
           "vkMapMemory");
  for (uint32_t index = 0; index < ELEMENT_COUNT; index++) {
    mapped_values[index] = index;
  }

  {
    const VkDescriptorSetLayoutBinding binding = {
        .binding = 0,
        .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
    };
    const VkDescriptorSetLayoutCreateInfo layout_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &binding,
    };
    check_vk(vkCreateDescriptorSetLayout(device, &layout_info, NULL,
                                         &descriptor_set_layout),
             "vkCreateDescriptorSetLayout");
  }
  {
    const VkPipelineLayoutCreateInfo layout_info = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &descriptor_set_layout,
    };
    check_vk(vkCreatePipelineLayout(device, &layout_info, NULL,
                                    &pipeline_layout),
             "vkCreatePipelineLayout");
  }

  if (shader_path == NULL || shader_path[0] == '\0') {
    shader_path = SHADER_PATH;
  }
  shader_words = read_shader(shader_path, &shader_word_count);
  {
    const VkShaderModuleCreateInfo shader_info = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = shader_word_count * sizeof(uint32_t),
        .pCode = shader_words,
    };
    check_vk(vkCreateShaderModule(device, &shader_info, NULL, &shader_module),
             "vkCreateShaderModule");
  }
  free(shader_words);
  {
    const VkPipelineShaderStageCreateInfo stage_info = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_COMPUTE_BIT,
        .module = shader_module,
        .pName = "main",
    };
    const VkComputePipelineCreateInfo pipeline_info = {
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = stage_info,
        .layout = pipeline_layout,
    };
    check_vk(vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &pipeline_info,
                                      NULL, &pipeline),
             "vkCreateComputePipelines");
  }

  {
    const VkDescriptorPoolSize pool_size = {
        .type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
    };
    const VkDescriptorPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 1,
        .poolSizeCount = 1,
        .pPoolSizes = &pool_size,
    };
    check_vk(vkCreateDescriptorPool(device, &pool_info, NULL, &descriptor_pool),
             "vkCreateDescriptorPool");
  }
  {
    const VkDescriptorSetAllocateInfo descriptor_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &descriptor_set_layout,
    };
    check_vk(vkAllocateDescriptorSets(device, &descriptor_info,
                                      &descriptor_set),
             "vkAllocateDescriptorSets");
  }
  {
    const VkDescriptorBufferInfo buffer_info = {
        .buffer = buffer,
        .offset = 0,
        .range = ELEMENT_COUNT * sizeof(uint32_t),
    };
    const VkWriteDescriptorSet write = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = descriptor_set,
        .dstBinding = 0,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .pBufferInfo = &buffer_info,
    };
    vkUpdateDescriptorSets(device, 1, &write, 0, NULL);
  }

  {
    const VkCommandPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = queue_family_index,
    };
    check_vk(vkCreateCommandPool(device, &pool_info, NULL, &command_pool),
             "vkCreateCommandPool");
  }
  {
    const VkCommandBufferAllocateInfo command_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = command_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    check_vk(vkAllocateCommandBuffers(device, &command_info, &command_buffer),
             "vkAllocateCommandBuffers");
  }
  {
    const VkCommandBufferBeginInfo begin_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    const VkMemoryBarrier barrier = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
    };
    check_vk(vkBeginCommandBuffer(command_buffer, &begin_info),
             "vkBeginCommandBuffer");
    vkCmdBindPipeline(command_buffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    vkCmdBindDescriptorSets(command_buffer, VK_PIPELINE_BIND_POINT_COMPUTE,
                            pipeline_layout, 0, 1, &descriptor_set, 0, NULL);
    vkCmdDispatch(command_buffer, ELEMENT_COUNT / LOCAL_SIZE, 1, 1);
    vkCmdPipelineBarrier(command_buffer, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &barrier, 0, NULL, 0,
                         NULL);
    check_vk(vkEndCommandBuffer(command_buffer), "vkEndCommandBuffer");
  }
  {
    const VkFenceCreateInfo fence_info = {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
    };
    const VkSubmitInfo submit_info = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer,
    };
    check_vk(vkCreateFence(device, &fence_info, NULL, &fence),
             "vkCreateFence");
    check_vk(vkQueueSubmit(queue, 1, &submit_info, fence), "vkQueueSubmit");
    check_vk(vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_MAX),
             "vkWaitForFences");
  }

  for (uint32_t index = 0; index < ELEMENT_COUNT; index++) {
    const uint32_t expected = index * 3u + 7u;
    if (mapped_values[index] != expected) {
      fprintf(stderr,
              "smolvm Vulkan compute smoke failed: output[%u] = %u, "
              "expected %u\n",
              index, mapped_values[index], expected);
      return EXIT_FAILURE;
    }
  }

  printf("Vulkan device: %s\n", physical_properties.deviceName);
  printf("Vulkan API: %u.%u.%u\n",
         VK_VERSION_MAJOR(physical_properties.apiVersion),
         VK_VERSION_MINOR(physical_properties.apiVersion),
         VK_VERSION_PATCH(physical_properties.apiVersion));
  printf("smolvm-vulkan-compute-smoke-ok\n");

  vkDestroyFence(device, fence, NULL);
  vkDestroyCommandPool(device, command_pool, NULL);
  vkDestroyDescriptorPool(device, descriptor_pool, NULL);
  vkDestroyPipeline(device, pipeline, NULL);
  vkDestroyShaderModule(device, shader_module, NULL);
  vkDestroyPipelineLayout(device, pipeline_layout, NULL);
  vkDestroyDescriptorSetLayout(device, descriptor_set_layout, NULL);
  vkUnmapMemory(device, memory);
  vkFreeMemory(device, memory, NULL);
  vkDestroyBuffer(device, buffer, NULL);
  vkDestroyDevice(device, NULL);
  vkDestroyInstance(instance, NULL);
  return EXIT_SUCCESS;
}
