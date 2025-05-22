#!/usr/bin/env python3
import matplotlib.pyplot as plt
import numpy as np
import re
import os

# Parse the benchmark results file
with open("doc/benchmark_results.txt", "r") as f:
    content = f.read()

# Extract platform sections
x86_section = re.search(r"x86_64.*?(?=riscv64|\Z)", content, re.DOTALL).group(0)
riscv_section = re.search(r"riscv64.*", content, re.DOTALL).group(0)

# Function to parse benchmark data from a section
def parse_section(section):
    pattern = r"(\w+(?:\s+-O\d+|\s+.*?transpile_O\d+\.c))\s+(\d+)ms"
    matches = re.findall(pattern, section)
    
    # Organize data by optimization level and execution method
    data = {}
    for method, time in matches:
        if "interpret" in method:
            category = "interpreter"
            opt_level = int(method[-1])
        elif "compile" in method:
            category = "native"
            opt_level = int(method[-1])
        elif "gcc" in method:
            category = "gcc"
            opt_level = int(method[-3])
        elif "clang" in method:
            category = "clang"
            opt_level = int(method[-3])
        else:
            continue
            
        if opt_level not in data:
            data[opt_level] = {}
        data[opt_level][category] = int(time)
    
    return data

# Parse data for both platforms
x86_data = parse_section(x86_section)
riscv_data = parse_section(riscv_section)

# Save directory
save_dir = "doc"
os.makedirs(save_dir, exist_ok=True)

# Plot settings
colors = {
    "interpreter": "#e13b59",  # red
    "native": "#f3ba14",       # orange
    "gcc": "#59a14f",          # green
    "clang": "#4e79a6"         # blue
}

labels = {
    "interpreter": "brainiac --interpret",
    "native": "brainiac --compile",
    "gcc": "gcc -O3",
    "clang": "clang -O3"
}

# Function to create the grouped bar chart
def create_bar_chart(data, title, filename, yticks, include_interpreter=True):
    # Select categories to include
    categories = ["interpreter", "native", "gcc", "clang"] if include_interpreter else ["native", "gcc", "clang"]
    
    # Prepare the data for grouped bars by optimization level
    opt_levels = sorted(data.keys())
    num_groups = len(opt_levels)
    num_bars_per_group = len(categories)
    group_width = 0.8  # 80% of the available space for each group
    bar_width = group_width / num_bars_per_group
    
    # Create figure and axis
    fig, ax = plt.subplots(figsize=(12, 8))
    plt.yticks(yticks)
    
    # Create bar groups
    for i, opt_level in enumerate(opt_levels):
        for j, category in enumerate(categories):
            # Position for this bar
            x_pos = i + (j - num_bars_per_group/2 + 0.5) * bar_width
            
            # Value for this bar
            value = data[opt_level].get(category, 0)
            
            # Create the bar
            bar = ax.bar(x_pos, value, bar_width - 0.02, 
                   label=labels[category] if i == 0 else "", 
                   color=colors[category])
            
            # Add value label on the bar
            if value > 0:
                ax.annotate(f"{value}",
                            xy=(x_pos, value),
                            xytext=(0, 3),  # 3 points vertical offset
                            textcoords="offset points",
                            ha="center", va="bottom", fontsize=9)
    
    ax.set_ylabel("Runtime in milliseconds")
    
    # Set chart labels and properties
    ax.set_xlabel("brainiac --transpile Optimization Level")
    ax.set_title(title)
    ax.set_xticks(np.arange(num_groups))
    ax.set_xticklabels([f"O{opt}" for opt in opt_levels])
    
    # Add legend
    ax.legend(loc="upper right")
    
    # Add a grid for easier reading
    ax.grid(axis="y", linestyle="--", alpha=0.5)
    
    # Set border color
    plt.setp(ax.spines.values(), color="#aaa")
    ax.tick_params(color="#aaa", labelcolor="#444")
    
    # Save the chart
    plt.tight_layout()
    plt.savefig(os.path.join(save_dir, filename))
    plt.close()

# Create charts for x86_64
create_bar_chart(
    x86_data, 
    "Mandelbrot.b runtime on x86_64 (Zen2 4.4GHz)",
    "benchmark_x86_all.png",
    np.arange(0, 22_000, 2_000),
    include_interpreter=True
)

create_bar_chart(
    x86_data, 
    "Mandelbrot.b runtime on x86_64 (Zen2 4.4GHz)",
    "benchmark_x86_compiled.png",
    np.arange(0, 2_300, 250),
    include_interpreter=False
)

# Create charts for riscv64
create_bar_chart(
    riscv_data, 
    "Mandelbrot.b runtime on riscv64 (Ky X1 1.6GHz)",
    "benchmark_riscv_all.png",
    np.arange(0, 120_000, 10_000),
    include_interpreter=True
)

create_bar_chart(
    riscv_data, 
    "Mandelbrot.b runtime on riscv64 (Ky X1 1.6GHz)",
    "benchmark_riscv_compiled.png",
    np.arange(0, 12_000, 1_000),
    include_interpreter=False
)

# Function to create speedup comparison chart
def create_speedup_chart(data, title, filename):
    categories = ["interpreter", "native", "gcc", "clang"]
    opt_levels = sorted(data.keys())[1:]  # Skip O0 as it"s the baseline
    
    # Calculate speedups relative to O0
    speedups = {}
    for category in categories:
        if category in data[0]:  # Check if category exists in O0
            baseline = data[0][category]
            speedups[category] = [baseline / data[opt][category] if category in data[opt] else 0 for opt in opt_levels]
    
    # Create the chart with grouped bars by optimization level
    num_groups = len(opt_levels)
    num_bars_per_group = len(speedups)
    group_width = 0.8
    bar_width = group_width / num_bars_per_group
    
    fig, ax = plt.subplots(figsize=(12, 8))
    
    for i, opt_level in enumerate(opt_levels):
        for j, (category, values) in enumerate(speedups.items()):
            # Skip if no speedup value for this optimization level
            if i >= len(values) or values[i] == 0:
                continue
                
            # Position for this bar
            x_pos = i + (j - num_bars_per_group/2 + 0.5) * bar_width
            
            # Value for this bar
            value = values[i]
            
            # Create the bar
            bar = ax.bar(x_pos, value, bar_width - 0.02,
                    label=labels[category] if i == 0 else "",
                    color=colors[category])
            
            # Add value label on the bar
            ax.annotate(f"{value:.1f}x",
                        xy=(x_pos, value),
                        xytext=(0, 3),  # 3 points vertical offset
                        textcoords="offset points",
                        ha="center", va="bottom", fontsize=8)
    
    # Set chart labels and properties
    ax.set_ylabel("Speedup (relative to O0)")
    ax.set_xlabel("Optimization Level")
    ax.set_title(title)
    ax.set_xticks(np.arange(len(opt_levels)))
    ax.set_xticklabels([f"O{opt}" for opt in opt_levels])
    ax.legend(loc="upper left")
    
    # Add a grid for easier reading
    ax.grid(axis="y", linestyle="--", alpha=0.7)
    
    # Set border color
    plt.setp(ax.spines.values(), color="#aaa")
    ax.tick_params(color="#aaa", labelcolor="#444")
    
    # Save the chart
    plt.tight_layout()
    plt.savefig(os.path.join(save_dir, filename))
    plt.close()

# Create speedup charts
create_speedup_chart(
    x86_data, 
    "Relative Speedup to Optimization Level O0 on x86_64",
    "benchmark_x86_speedup.png"
)

create_speedup_chart(
    riscv_data, 
    "Relative Speedup to Optimization Level O0 on riscv64",
    "benchmark_riscv_speedup.png"
)

print("Charts generated successfully in the \"doc\" directory.")
