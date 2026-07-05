import cv2
import numpy as np

img = np.ones((800, 400), dtype=np.uint8) * 255

lines = [
    ("MYDIN MALL", 30, 50, 1.2),
    ("No 1 Jalan Utama, KL", 18, 90, 0.7),
    ("Tel: 03-12345678", 18, 120, 0.7),
    ("--------------------------------", 16, 150, 0.6),
    ("DATE: 29/06/2026", 18, 180, 0.7),
    ("--------------------------------", 16, 210, 0.6),
    ("Nasi Lemak          RM 5.50", 18, 250, 0.7),
    ("Teh Tarik           RM 2.00", 18, 280, 0.7),
    ("Roti Canai          RM 2.50", 18, 310, 0.7),
    ("--------------------------------", 16, 340, 0.6),
    ("TOTAL               RM 10.00", 20, 380, 0.9),
    ("--------------------------------", 16, 410, 0.6),
    ("CASH                RM 20.00", 18, 450, 0.7),
    ("CHANGE              RM 10.00", 18, 480, 0.7),
    ("--------------------------------", 16, 510, 0.6),
    ("Thank you!", 18, 550, 0.7),
    ("WARRANTY: 1 MONTH", 16, 590, 0.6),
]

for text, size, y, scale in lines:
    cv2.putText(img, text, (20, y), cv2.FONT_HERSHEY_SIMPLEX, scale, 0, 2)

cv2.imwrite("test_receipt.png", img)
print("test_receipt.png created successfully")
