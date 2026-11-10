select
    order_id,
    customer_id,
    amount,
    updated_at
from {{ source('shop', 'orders') }}
