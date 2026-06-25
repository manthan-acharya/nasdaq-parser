// High-performance Linux kernel driver for the HFT FPGA DMA bridge allocating coherent physical RAM and exposing user-space mmap.

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/pci.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/uaccess.h>
#include <linux/dma-mapping.h>
#include <linux/mm.h>

#define MODULE_NAME        "hft_pcie_driver"
#define PCI_VENDOR_ID_HFT  0x10EE  // Mock Xilinx Vendor ID
#define PCI_DEVICE_ID_HFT  0x7022  // Mock Device ID
#define DMA_BUFFER_SIZE    (1024 * 1024) // 1MB Ring Buffer

// FPGA BAR0 Register Offsets
#define REG_CTRL           0x00
#define REG_BASE_LOW       0x04
#define REG_BASE_HIGH      0x08
#define REG_BUF_SIZE       0x0C
#define REG_WR_OFFSET      0x10

// Struct to hold device private data
struct hft_dev {
    struct pci_dev *pdev;
    void __iomem *bar0_ptr;
    
    // DMA Buffer Info
    void *dma_virt_addr;
    dma_addr_t dma_phys_addr;
    
    // Character Device Info
    dev_t dev_num;
    struct cdev cdev;
    struct class *class;
    struct device *device;
};

static struct hft_dev *hft_device = NULL;

static int hft_open(struct inode *inode, struct file *filp)
{
    filp->private_data = hft_device;
    return 0;
}

static int hft_release(struct inode *inode, struct file *filp)
{
    return 0;
}

// Zero-copy mapping of coherent DMA RAM into user-space
static int hft_mmap(struct file *filp, struct vm_area_struct *vma)
{
    struct hft_dev *dev = filp->private_data;
    unsigned long size = vma->vm_end - vma->vm_start;
    int ret;

    if (size > DMA_BUFFER_SIZE) {
        pr_err("%s: Requested mmap size %lu exceeds DMA buffer size %d\n",
               MODULE_NAME, size, DMA_BUFFER_SIZE);
        return -EINVAL;
    }

    // Set page attributes to non-cached for coherent memory consistency
    vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);

    // Map physical pages directly to user-space
    ret = dma_mmap_coherent(&dev->pdev->dev, vma, dev->dma_virt_addr,
                            dev->dma_phys_addr, DMA_BUFFER_SIZE);
    if (ret < 0) {
        pr_err("%s: dma_mmap_coherent failed with code %d\n", MODULE_NAME, ret);
        return ret;
    }

    pr_info("%s: Coherent DMA buffer mapped to user-space at 0x%lx\n",
            MODULE_NAME, vma->vm_start);
    return 0;
}

static const struct file_operations hft_fops = {
    .owner          = THIS_MODULE,
    .open           = hft_open,
    .release        = hft_release,
    .mmap           = hft_mmap,
};

static int hft_pci_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    int ret;
    u32 addr_low, addr_high;

    pr_info("%s: Probing PCI device...\n", MODULE_NAME);

    // Allocate memory for device container
    hft_device = kzalloc(sizeof(struct hft_dev), GFP_KERNEL);
    if (!hft_device)
        return -ENOMEM;

    hft_device->pdev = pdev;

    // Enable device
    ret = pci_enable_device(pdev);
    if (ret) {
        pr_err("%s: Failed to enable PCI device\n", MODULE_NAME);
        goto err_free_dev;
    }

    // Request PCI memory region
    ret = pci_request_regions(pdev, MODULE_NAME);
    if (ret) {
        pr_err("%s: Failed to request PCI regions\n", MODULE_NAME);
        goto err_disable_pci;
    }

    // Map BAR0 into kernel memory
    hft_device->bar0_ptr = pci_iomap(pdev, 0, 0);
    if (!hft_device->bar0_ptr) {
        pr_err("%s: Failed to map BAR0\n", MODULE_NAME);
        ret = -ENOMEM;
        goto err_release_regions;
    }

    // Configure 64-bit DMA mask
    ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
    if (ret) {
        pr_warn("%s: 64-bit DMA not supported, trying 32-bit mask...\n", MODULE_NAME);
        ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
        if (ret) {
            pr_err("%s: DMA mask configuration failed\n", MODULE_NAME);
            goto err_iounmap;
        }
    }

    // Allocate contiguous coherent physical RAM
    hft_device->dma_virt_addr = dma_alloc_coherent(&pdev->dev, DMA_BUFFER_SIZE,
                                                   &hft_device->dma_phys_addr, GFP_KERNEL);
    if (!hft_device->dma_virt_addr) {
        pr_err("%s: Failed to allocate coherent DMA memory\n", MODULE_NAME);
        ret = -ENOMEM;
        goto err_iounmap;
    }

    pr_info("%s: Allocated coherent DMA buffer (Virt: %p, Phys: %pad)\n",
            MODULE_NAME, hft_device->dma_virt_addr, &hft_device->dma_phys_addr);

    // Initialize character device interface for mmap mapping
    ret = alloc_chrdev_region(&hft_device->dev_num, 0, 1, MODULE_NAME);
    if (ret < 0) {
        pr_err("%s: Failed to allocate character device region\n", MODULE_NAME);
        goto err_free_dma;
    }

    cdev_init(&hft_device->cdev, &hft_fops);
    hft_device->cdev.owner = THIS_MODULE;
    ret = cdev_add(&hft_device->cdev, hft_device->dev_num, 1);
    if (ret < 0) {
        pr_err("%s: Failed to add character device\n", MODULE_NAME);
        goto err_unregister_chrdev;
    }

    hft_device->class = class_create(MODULE_NAME);
    if (IS_ERR(hft_device->class)) {
        pr_err("%s: Failed to create device class\n", MODULE_NAME);
        ret = PTR_ERR(hft_device->class);
        goto err_cdev_del;
    }

    hft_device->device = device_create(hft_device->class, NULL, hft_device->dev_num,
                                       NULL, "hft_dma");
    if (IS_ERR(hft_device->device)) {
        pr_err("%s: Failed to create device file\n", MODULE_NAME);
        ret = PTR_ERR(hft_device->device);
        goto err_class_destroy;
    }

    // Write base address to FPGA MMIO configuration registers
    addr_low  = (u32)(hft_device->dma_phys_addr & 0xFFFFFFFFULL);
    addr_high = (u32)((hft_device->dma_phys_addr >> 32) & 0xFFFFFFFFULL);

    iowrite32(addr_low,  hft_device->bar0_ptr + REG_BASE_LOW);
    iowrite32(addr_high, hft_device->bar0_ptr + REG_BASE_HIGH);
    iowrite32(DMA_BUFFER_SIZE, hft_device->bar0_ptr + REG_BUF_SIZE);
    
    // Enable the DMA Controller (Bit 0) and clear offset (Bit 1)
    iowrite32(0x00000003, hft_device->bar0_ptr + REG_CTRL);

    pr_info("%s: Device initialized and DMA enabled in hardware.\n", MODULE_NAME);
    return 0;

err_class_destroy:
    class_destroy(hft_device->class);
err_cdev_del:
    cdev_del(&hft_device->cdev);
err_unregister_chrdev:
    unregister_chrdev_region(hft_device->dev_num, 1);
err_free_dma:
    dma_free_coherent(&pdev->dev, DMA_BUFFER_SIZE, hft_device->dma_virt_addr,
                      hft_device->dma_phys_addr);
err_iounmap:
    pci_iounmap(pdev, hft_device->bar0_ptr);
err_release_regions:
    pci_release_regions(pdev);
err_disable_pci:
    pci_disable_device(pdev);
err_free_dev:
    kfree(hft_device);
    hft_device = NULL;
    return ret;
}

static void hft_pci_remove(struct pci_dev *pdev)
{
    if (hft_device) {
        // Disable DMA in hardware
        iowrite32(0x00000000, hft_device->bar0_ptr + REG_CTRL);

        device_destroy(hft_device->class, hft_device->dev_num);
        class_destroy(hft_device->class);
        cdev_del(&hft_device->cdev);
        unregister_chrdev_region(hft_device->dev_num, 1);

        dma_free_coherent(&pdev->dev, DMA_BUFFER_SIZE, hft_device->dma_virt_addr,
                          hft_device->dma_phys_addr);
        pci_iounmap(pdev, hft_device->bar0_ptr);
        pci_release_regions(pdev);
        pci_disable_device(pdev);
        kfree(hft_device);
        hft_device = NULL;
    }
    pr_info("%s: Device driver unloaded successfully.\n", MODULE_NAME);
}

// PCI device ID table matching the Vendor/Device IDs
static const struct pci_device_id hft_pci_ids[] = {
    { PCI_DEVICE(PCI_VENDOR_ID_HFT, PCI_DEVICE_ID_HFT) },
    { 0, }
};
MODULE_DEVICE_TABLE(pci, hft_pci_ids);

static struct pci_driver hft_pci_driver = {
    .name     = MODULE_NAME,
    .id_table = hft_pci_ids,
    .probe    = hft_pci_probe,
    .remove   = hft_pci_remove,
};

module_pci_driver(hft_pci_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Senior FPGA Hardware-Software Engineer");
MODULE_DESCRIPTION("Low-latency FPGA direct-to-host DMA character device driver");
MODULE_VERSION("1.0");
