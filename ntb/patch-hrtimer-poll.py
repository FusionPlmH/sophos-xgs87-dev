import os, sys
B = (sys.argv[1] if len(sys.argv) > 1 else "/srv/npu/build/ntb")
p = os.path.join(B, "pci_epf_vntb.c")
s = open(p).read()

if "poll_timer" in s:
    print("already patched"); sys.exit(0)

def sub(old, new, tag):
    global s
    assert old in s, "missing: " + tag
    s = s.replace(old, new, 1)
    print("ok:", tag)

sub("#include <linux/pci-epf.h>",
    "#include <linux/hrtimer.h>\n#include <linux/pci-epf.h>", "include")

sub("\tstruct delayed_work cmd_handler;\n};",
    "\tstruct delayed_work cmd_handler;\n"
    "\tstruct hrtimer poll_timer;\n"
    "\tu64 poll_ns;\n"
    "\tunsigned int idle_polls;\n};", "struct")

sub("""/**
 * epf_ntb_cmd_handler() - Handle commands provided by the NTB HOST""",
"""/*
 * The host rings us by writing the doorbell BAR, and that raises no interrupt
 * on this side, so the endpoint has to poll.  A delayed_work gives that poll
 * jiffy granularity: at HZ=250 the 1-jiffy re-arm is 4 ms, which lands
 * straight in the round-trip latency.  An hrtimer polls below jiffy
 * resolution while traffic flows and backs off once it goes quiet.
 */
#define VNTB_POLL_BUSY_NS	250000ULL	/* 250 us, traffic flowing */
#define VNTB_POLL_IDLE_NS	1000000ULL	/* 1 ms, nothing happening */
#define VNTB_POLL_IDLE_AFTER	8

static enum hrtimer_restart epf_ntb_poll_timer(struct hrtimer *timer)
{
	struct epf_ntb *ntb = container_of(timer, struct epf_ntb, poll_timer);

	queue_work(kpcintb_workqueue, &ntb->cmd_handler.work);
	hrtimer_forward_now(timer, ns_to_ktime(ntb->poll_ns));
	return HRTIMER_RESTART;
}

/**
 * epf_ntb_cmd_handler() - Handle commands provided by the NTB HOST""", "callback")

sub("""			ntb->epf_db[i] = 0;
		}
	}

	ctrl = ntb->reg;
	command = ctrl->command;
	if (!command)
		goto reset_handler;""",
"""			ntb->epf_db[i] = 0;
			ntb->idle_polls = 0;
			ntb->poll_ns = VNTB_POLL_BUSY_NS;
		}
	}

	ctrl = ntb->reg;
	command = ctrl->command;
	if (!command) {
		if (++ntb->idle_polls > VNTB_POLL_IDLE_AFTER)
			ntb->poll_ns = VNTB_POLL_IDLE_NS;
		goto reset_handler;
	}
	ntb->idle_polls = 0;
	ntb->poll_ns = VNTB_POLL_BUSY_NS;""", "activity")

sub("""reset_handler:
	queue_delayed_work(kpcintb_workqueue, &ntb->cmd_handler,
			   msecs_to_jiffies(1));
}""",
"""reset_handler:
	/* epf_ntb_poll_timer() re-queues us */
}""", "rearm")

sub("""	INIT_DELAYED_WORK(&ntb->cmd_handler, epf_ntb_cmd_handler);
	queue_work(kpcintb_workqueue, &ntb->cmd_handler.work);""",
"""	INIT_DELAYED_WORK(&ntb->cmd_handler, epf_ntb_cmd_handler);
	hrtimer_init(&ntb->poll_timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
	ntb->poll_timer.function = epf_ntb_poll_timer;
	ntb->poll_ns = VNTB_POLL_BUSY_NS;
	ntb->idle_polls = 0;
	hrtimer_start(&ntb->poll_timer, ns_to_ktime(ntb->poll_ns),
		      HRTIMER_MODE_REL);""", "init")

sub("""	disable_delayed_work_sync(&ntb->cmd_handler);""",
"""	hrtimer_cancel(&ntb->poll_timer);
	disable_delayed_work_sync(&ntb->cmd_handler);""", "cleanup")

open(p, "w").write(s)
print("patched")
