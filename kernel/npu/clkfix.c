// SPDX-License-Identifier: GPL-2.0
/*
 * clkfix - keep the Armada/OcteonTX CP115 EIP197 crypto clocks enabled.
 *
 * The safexcel driver never claims the "core"/"reg" clocks described in the
 * crypto device tree node, so clk_disable_unused() gates them at
 * late_initcall and the EIP197 PE microcode can never start
 * ("FW(1) for PE 0 failed to start").  Claim and enable them here instead of
 * patching the in-tree driver.
 */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/clk.h>
#include <linux/err.h>

static struct clk *eip_core;
static struct clk *eip_reg;

static struct clk *claim(struct device_node *np, const char *name)
{
	struct clk *clk = of_clk_get_by_name(np, name);
	int ret;

	if (IS_ERR(clk)) {
		pr_warn("clkfix: no %s clock: %ld\n", name, PTR_ERR(clk));
		return NULL;
	}

	ret = clk_prepare_enable(clk);
	if (ret) {
		pr_warn("clkfix: cannot enable %s clock: %d\n", name, ret);
		clk_put(clk);
		return NULL;
	}

	pr_info("clkfix: %s clock enabled at %lu Hz\n", name, clk_get_rate(clk));
	return clk;
}

static int __init clkfix_init(void)
{
	struct device_node *np;

	np = of_find_compatible_node(NULL, NULL, "inside-secure,safexcel-eip197b");
	if (!np)
		np = of_find_compatible_node(NULL, NULL, "inside-secure,safexcel-eip97");
	if (!np)
		return -ENODEV;

	eip_core = claim(np, "core");
	eip_reg = claim(np, "reg");
	of_node_put(np);

	if (!eip_core && !eip_reg)
		return -ENODEV;

	return 0;
}

static void __exit clkfix_exit(void)
{
	if (eip_reg) {
		clk_disable_unprepare(eip_reg);
		clk_put(eip_reg);
	}
	if (eip_core) {
		clk_disable_unprepare(eip_core);
		clk_put(eip_core);
	}
}

module_init(clkfix_init);
module_exit(clkfix_exit);
MODULE_DESCRIPTION("Keep the CP115 EIP197 crypto clocks enabled");
MODULE_LICENSE("GPL");
