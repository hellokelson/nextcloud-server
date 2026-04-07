#!/usr/bin/env python3
"""
Nextcloud AWS Cost Calculator
Estimates monthly AWS costs based on usage patterns
"""

import json
import sys
from typing import Dict, Tuple

# AWS Pricing (US-East-1, as of 2024)
PRICING = {
    # Fargate (per vCPU-hour and per GB-hour)
    'fargate_vcpu_hour': 0.04048,
    'fargate_gb_hour': 0.004445,

    # Aurora Serverless v2 (per ACU-hour)
    'aurora_acu_hour': 0.12,

    # ElastiCache Serverless
    'elasticache_gb_month': 0.125,  # Data storage
    'elasticache_ecpu_million': 0.0034,  # Per million ECPUs

    # S3 Standard
    's3_storage_gb_month': 0.023,
    's3_put_1000': 0.005,
    's3_get_1000': 0.0004,

    # ALB
    'alb_hour': 0.0225,
    'alb_lcu_hour': 0.008,

    # EFS
    'efs_gb_month': 0.30,

    # Data Transfer
    'data_transfer_gb': 0.09,
}

# Hours per month
HOURS_PER_MONTH = 730


class CostCalculator:
    def __init__(self, config: Dict):
        self.config = config
        self.breakdown = {}

    def calculate_fargate_cost(self) -> float:
        """Calculate Fargate costs"""
        num_tasks = self.config.get('num_tasks', 3)
        vcpu = self.config.get('vcpu', 1)
        memory_gb = self.config.get('memory_gb', 2)

        vcpu_cost = num_tasks * vcpu * PRICING['fargate_vcpu_hour'] * HOURS_PER_MONTH
        memory_cost = num_tasks * memory_gb * PRICING['fargate_gb_hour'] * HOURS_PER_MONTH

        total = vcpu_cost + memory_cost
        self.breakdown['fargate'] = {
            'vcpu_cost': round(vcpu_cost, 2),
            'memory_cost': round(memory_cost, 2),
            'total': round(total, 2),
            'details': f'{num_tasks} tasks × {vcpu} vCPU × {memory_gb} GB'
        }
        return total

    def calculate_aurora_cost(self) -> float:
        """Calculate Aurora Serverless v2 costs"""
        min_acu = self.config.get('aurora_min_acu', 0.5)
        max_acu = self.config.get('aurora_max_acu', 16)
        avg_utilization = self.config.get('aurora_avg_utilization', 0.3)

        # Estimate average ACU based on min, max, and utilization
        avg_acu = min_acu + (max_acu - min_acu) * avg_utilization

        # Aurora charges for 2 instances minimum (primary + replica)
        num_instances = 2
        total = avg_acu * num_instances * PRICING['aurora_acu_hour'] * HOURS_PER_MONTH

        self.breakdown['aurora'] = {
            'min_acu': min_acu,
            'max_acu': max_acu,
            'avg_acu': round(avg_acu, 2),
            'num_instances': num_instances,
            'total': round(total, 2),
            'details': f'{num_instances} instances × {avg_acu:.1f} ACU avg'
        }
        return total

    def calculate_elasticache_cost(self) -> float:
        """Calculate ElastiCache Serverless costs"""
        data_storage_gb = self.config.get('redis_data_gb', 5)
        requests_per_month = self.config.get('redis_requests_per_month', 100_000_000)

        storage_cost = data_storage_gb * PRICING['elasticache_gb_month']

        # ECPUs are consumed based on request complexity
        # Estimate: 1 ECPU per 1000 simple requests
        ecpu_millions = (requests_per_month / 1000) / 1_000_000
        request_cost = ecpu_millions * PRICING['elasticache_ecpu_million']

        total = storage_cost + request_cost
        self.breakdown['elasticache'] = {
            'storage_cost': round(storage_cost, 2),
            'request_cost': round(request_cost, 2),
            'total': round(total, 2),
            'details': f'{data_storage_gb} GB + {requests_per_month/1_000_000:.0f}M requests'
        }
        return total

    def calculate_s3_cost(self) -> float:
        """Calculate S3 costs"""
        storage_gb = self.config.get('s3_storage_gb', 100)
        uploads_per_month = self.config.get('s3_uploads_per_month', 10_000)
        downloads_per_month = self.config.get('s3_downloads_per_month', 50_000)

        storage_cost = storage_gb * PRICING['s3_storage_gb_month']
        put_cost = (uploads_per_month / 1000) * PRICING['s3_put_1000']
        get_cost = (downloads_per_month / 1000) * PRICING['s3_get_1000']

        total = storage_cost + put_cost + get_cost
        self.breakdown['s3'] = {
            'storage_cost': round(storage_cost, 2),
            'put_cost': round(put_cost, 2),
            'get_cost': round(get_cost, 2),
            'total': round(total, 2),
            'details': f'{storage_gb} GB + {uploads_per_month:,} uploads + {downloads_per_month:,} downloads'
        }
        return total

    def calculate_alb_cost(self) -> float:
        """Calculate ALB costs"""
        # LCU calculation is complex, simplified here
        requests_per_month = self.config.get('alb_requests_per_month', 1_000_000)
        avg_request_size_kb = self.config.get('alb_avg_request_size_kb', 10)

        # Fixed cost
        fixed_cost = PRICING['alb_hour'] * HOURS_PER_MONTH

        # LCU estimation (simplified)
        # 1 LCU = 25 new connections/sec OR 3000 active connections OR 1 GB/hour processed
        gb_processed = (requests_per_month * avg_request_size_kb) / (1024 * 1024)
        lcu_hours = gb_processed  # Simplified
        variable_cost = lcu_hours * PRICING['alb_lcu_hour']

        total = fixed_cost + variable_cost
        self.breakdown['alb'] = {
            'fixed_cost': round(fixed_cost, 2),
            'variable_cost': round(variable_cost, 2),
            'total': round(total, 2),
            'details': f'{requests_per_month/1_000_000:.1f}M requests/month'
        }
        return total

    def calculate_efs_cost(self) -> float:
        """Calculate EFS costs"""
        storage_gb = self.config.get('efs_storage_gb', 10)

        total = storage_gb * PRICING['efs_gb_month']
        self.breakdown['efs'] = {
            'storage_gb': storage_gb,
            'total': round(total, 2),
            'details': f'{storage_gb} GB config/apps storage'
        }
        return total

    def calculate_data_transfer_cost(self) -> float:
        """Calculate data transfer costs"""
        # Only outbound data transfer is charged
        gb_out_per_month = self.config.get('data_transfer_out_gb', 100)

        # First 100 GB/month is free
        billable_gb = max(0, gb_out_per_month - 100)
        total = billable_gb * PRICING['data_transfer_gb']

        self.breakdown['data_transfer'] = {
            'total_gb': gb_out_per_month,
            'free_gb': min(gb_out_per_month, 100),
            'billable_gb': billable_gb,
            'total': round(total, 2),
            'details': f'{gb_out_per_month} GB out (first 100 GB free)'
        }
        return total

    def calculate_total(self) -> Dict:
        """Calculate total monthly cost"""
        costs = {
            'fargate': self.calculate_fargate_cost(),
            'aurora': self.calculate_aurora_cost(),
            'elasticache': self.calculate_elasticache_cost(),
            's3': self.calculate_s3_cost(),
            'alb': self.calculate_alb_cost(),
            'efs': self.calculate_efs_cost(),
            'data_transfer': self.calculate_data_transfer_cost(),
        }

        total = sum(costs.values())

        return {
            'monthly_total': round(total, 2),
            'yearly_total': round(total * 12, 2),
            'breakdown': self.breakdown,
            'summary': {
                component: round(cost, 2)
                for component, cost in costs.items()
            }
        }


# Predefined scenarios
SCENARIOS = {
    'small': {
        'name': 'Small Team (10-50 users)',
        'description': 'Low traffic, minimal storage',
        'config': {
            'num_tasks': 2,
            'vcpu': 1,
            'memory_gb': 2,
            'aurora_min_acu': 0.5,
            'aurora_max_acu': 4,
            'aurora_avg_utilization': 0.2,
            'redis_data_gb': 2,
            'redis_requests_per_month': 50_000_000,
            's3_storage_gb': 50,
            's3_uploads_per_month': 5_000,
            's3_downloads_per_month': 25_000,
            'alb_requests_per_month': 500_000,
            'alb_avg_request_size_kb': 10,
            'efs_storage_gb': 5,
            'data_transfer_out_gb': 50,
        }
    },
    'medium': {
        'name': 'Medium Business (100-500 users)',
        'description': 'Moderate traffic, growing storage',
        'config': {
            'num_tasks': 3,
            'vcpu': 1,
            'memory_gb': 2,
            'aurora_min_acu': 1,
            'aurora_max_acu': 8,
            'aurora_avg_utilization': 0.3,
            'redis_data_gb': 5,
            'redis_requests_per_month': 200_000_000,
            's3_storage_gb': 500,
            's3_uploads_per_month': 20_000,
            's3_downloads_per_month': 100_000,
            'alb_requests_per_month': 5_000_000,
            'alb_avg_request_size_kb': 15,
            'efs_storage_gb': 10,
            'data_transfer_out_gb': 200,
        }
    },
    'large': {
        'name': 'Large Enterprise (1000+ users)',
        'description': 'High traffic, substantial storage',
        'config': {
            'num_tasks': 6,
            'vcpu': 2,
            'memory_gb': 4,
            'aurora_min_acu': 2,
            'aurora_max_acu': 32,
            'aurora_avg_utilization': 0.4,
            'redis_data_gb': 10,
            'redis_requests_per_month': 1_000_000_000,
            's3_storage_gb': 5000,
            's3_uploads_per_month': 100_000,
            's3_downloads_per_month': 500_000,
            'alb_requests_per_month': 50_000_000,
            'alb_avg_request_size_kb': 20,
            'efs_storage_gb': 20,
            'data_transfer_out_gb': 1000,
        }
    }
}


def print_cost_report(scenario_name: str, results: Dict):
    """Print formatted cost report"""
    scenario = SCENARIOS[scenario_name]

    print(f"\n{'='*70}")
    print(f"  {scenario['name']}")
    print(f"  {scenario['description']}")
    print(f"{'='*70}\n")

    print("Cost Breakdown:")
    print(f"{'─'*70}")

    for component, cost in results['summary'].items():
        details = results['breakdown'][component].get('details', '')
        print(f"  {component.upper():20s} ${cost:>8.2f}/mo  {details}")

    print(f"{'─'*70}")
    print(f"  {'MONTHLY TOTAL':20s} ${results['monthly_total']:>8.2f}")
    print(f"  {'YEARLY TOTAL':20s} ${results['yearly_total']:>8.2f}")
    print(f"{'─'*70}\n")


def compare_scenarios():
    """Compare all scenarios"""
    print("\n" + "="*70)
    print("  Nextcloud AWS Cost Comparison")
    print("="*70)

    results = {}
    for scenario_name in SCENARIOS:
        calculator = CostCalculator(SCENARIOS[scenario_name]['config'])
        results[scenario_name] = calculator.calculate_total()

    print("\nMonthly Cost Comparison:")
    print(f"{'─'*70}")
    print(f"{'Scenario':<30s} {'Monthly':<15s} {'Yearly':<15s}")
    print(f"{'─'*70}")

    for scenario_name, result in results.items():
        name = SCENARIOS[scenario_name]['name']
        monthly = result['monthly_total']
        yearly = result['yearly_total']
        print(f"{name:<30s} ${monthly:<14.2f} ${yearly:<14.2f}")

    print(f"{'─'*70}\n")

    return results


def main():
    if len(sys.argv) > 1:
        scenario = sys.argv[1]
        if scenario == 'compare':
            compare_scenarios()
        elif scenario in SCENARIOS:
            calculator = CostCalculator(SCENARIOS[scenario]['config'])
            results = calculator.calculate_total()
            print_cost_report(scenario, results)
        elif scenario == 'custom':
            print("Custom configuration mode:")
            print("Usage: Modify the script to add your custom config")
        else:
            print(f"Unknown scenario: {scenario}")
            print(f"Available scenarios: {', '.join(SCENARIOS.keys())}, compare, custom")
            sys.exit(1)
    else:
        # Default: show all scenarios
        results = compare_scenarios()

        print("\nDetailed breakdown for 'medium' scenario:")
        calculator = CostCalculator(SCENARIOS['medium']['config'])
        results = calculator.calculate_total()
        print_cost_report('medium', results)


if __name__ == '__main__':
    main()
